@with_kw mutable struct DeepQLearningSolver
    qnetwork::Any = nothing # intended to be a flux model 
    learning_rate::Float64 = 1e-4
    max_steps::Int64 = 1000
    batch_size::Int64 = 32
    train_freq::Int64 = 4
    eval_freq::Int64 = 500
    target_update_freq::Int64 = 500
    num_ep_eval::Int64 = 100
    double_q::Bool = true 
    dueling::Bool = true
    recurrence::Bool = false
    eps_fraction::Float64 = 0.5
    eps_end::Float64 = 0.01
    evaluation_policy::Any = basic_evaluation
    exploration_policy::Any = linear_epsilon_greedy(max_steps, eps_fraction, eps_end)
    trace_length::Int64 = 40
    prioritized_replay::Bool = true
    prioritized_replay_alpha::Float64 = 0.6
    prioritized_replay_epsilon::Float64 = 1e-6
    prioritized_replay_beta::Float64 = 0.4
    buffer_size::Int64 = 1000
    max_episode_length::Int64 = 100
    train_start::Int64 = 200
    grad_clip::Bool = true
    clip_val::Float64 = 10.0
    rng::AbstractRNG = MersenneTwister(0)
    logdir::String = "log"
    save_freq::Int64 = 10000
    log_freq::Int64 = 100
    verbose::Bool = true
end

function POMDPs.solve(solver::DeepQLearningSolver, problem::MDP)
    env = MDPEnvironment(problem, rng=solver.rng)
    return solve(solver, env)
end

function POMDPs.solve(solver::DeepQLearningSolver, problem::POMDP)
    env = POMDPEnvironment(problem, rng=solver.rng)
    return solve(solver, env)
end

function POMDPs.solve(solver::DeepQLearningSolver, env::AbstractEnvironment)
    # check reccurence 
    if isrecurrent(solver.qnetwork) && !solver.recurrence
        throw("DeepQLearningError: you passed in a recurrent model but recurrence is set to false")
    end
    replay = initialize_replay_buffer(solver, env)
    if solver.dueling 
        active_q = create_dueling_network(solver.qnetwork)
    else
        active_q = solver.qnetwork
    end
    policy = NNPolicy(env.problem, active_q, ordered_actions(env.problem), length(obs_dimensions(env)))
    target_q = deepcopy(solver.qnetwork)
    optimizer = ADAM(Flux.params(active_q), solver.learning_rate)
    # start training
    reset!(policy)
    obs = reset(env)
    done = false
    step = 0
    rtot = 0
    episode_rewards = Float64[0.0]
    episode_steps = Float64[]
    saved_mean_reward = 0.
    scores_eval = 0.
    model_saved = false
    for t=1:solver.max_steps 
        act, eps = exploration(solver.exploration_policy, policy, env, obs, t, solver.rng)
        ai = actionindex(env.problem, act)
        op, rew, done, info = step!(env, act)
        exp = DQExperience(obs, ai, rew, op, done)
        add_exp!(replay, exp)
        obs = op
        step += 1
        episode_rewards[end] += rew
        if done || step >= solver.max_episode_length
            obs = reset(env)
            reset!(policy)
            push!(episode_steps, step)
            push!(episode_rewards, 0.0)
            done = false
            step = 0
            rtot = 0
        end
        num_episodes = length(episode_rewards)
        avg100_reward = mean(episode_rewards[max(1, length(episode_rewards)-101):end])
        avg100_steps = mean(episode_steps[max(1, length(episode_steps)-101):end])
        if t%solver.train_freq == 0       
            hs = hiddenstates(active_q)
            loss_val, td_errors, grad_val = batch_train!(solver, env, optimizer, active_q, target_q, replay)
            sethiddenstates!(active_q, hs)
        end

        if t%solver.target_update_freq == 0
            target_q = deepcopy(active_q)
        end

        if t%solver.eval_freq == 0
            scores_eval = evaluation(solver.evaluation_policy, 
                                 policy, env,                                  
                                 solver.num_ep_eval,
                                 solver.max_episode_length,
                                 solver.verbose)
        end

        if t%solver.log_freq == 0
            #TODO log the training perf somewhere (?dataframes/csv?)
            if  solver.verbose
                @printf("%5d / %5d eps %0.3f |  avgR %1.3f | Loss %2.3e | Grad %2.3e \n",
                        t, solver.max_steps, eps, avg100_reward, loss_val, grad_val)
            end             
        end

    end # end training
    return policy
end



function initialize_replay_buffer(solver::DeepQLearningSolver, env::AbstractEnvironment)
    # init and populate replay buffer
    if solver.recurrence
        replay = EpisodeReplayBuffer(env, solver.buffer_size, solver.batch_size, solver.trace_length)
    elseif solver.prioritized_replay
        replay = PrioritizedReplayBuffer(env, solver.buffer_size, solver.batch_size)
    else
        replay = ReplayBuffer(env, solver.buffer_size, solver.batch_size)
    end
    populate_replay_buffer!(replay, env, max_pop=solver.train_start)
    return replay #XXX type unstable
end


function loss(td)
    l = mean(huber_loss.(td))
    return l
end

function batch_train!(solver::DeepQLearningSolver,
                      env::AbstractEnvironment,
                      optimizer, 
                      active_q, 
                      target_q,
                      s_batch, a_batch, r_batch, sp_batch, done_batch, importance_weights)
    q_values = active_q(s_batch) # n_actions x batch_size
    q_sa = [q_values[a_batch[i], i] for i=1:solver.batch_size] # maybe not ideal
    if solver.double_q
        target_q_values = target_q(sp_batch)
        qp_values = active_q(sp_batch)
        # best_a = argmax(qp_values, dims=1) # fails with TrackedArrays.
        # q_sp_max = target_q_values[best_a]
        q_sp_max = vec([target_q_values[argmax(qp_values[:,i]), i] for i=1:solver.batch_size])
    else
        q_sp_max = @view maximum(target_q(sp_batch), dims=1)[:]
    end
    q_targets = r_batch .+ (1.0 .- done_batch).*discount(env.problem).*q_sp_max 
    td_tracked = q_sa .- q_targets
    loss_tracked = loss(importance_weights.*td_tracked)
    loss_val = loss_tracked.data
    # td_vals = [td_tracked[i].data for i=1:solver.batch_size]
    td_vals = Flux.data.(td_tracked)
    Flux.back!(loss_tracked)
    grad_norm = globalnorm(params(active_q))
    optimizer()
    return loss_val, td_vals, grad_norm
end

function batch_train!(solver::DeepQLearningSolver,
                      env::AbstractEnvironment,
                      optimizer, 
                      active_q, 
                      target_q,
                      replay::ReplayBuffer)
    s_batch, a_batch, r_batch, sp_batch, done_batch = sample(replay)
    return batch_train!(solver, env, optimizer, active_q, target_q, s_batch, a_batch, r_batch, sp_batch, done_batch, ones(solver.batch_size))
end

function batch_train!(solver::DeepQLearningSolver,
                      env::AbstractEnvironment,
                      optimizer, 
                      active_q, 
                      target_q,
                      replay::PrioritizedReplayBuffer)
    s_batch, a_batch, r_batch, sp_batch, done_batch, indices, weights = sample(replay)
    loss_val, td_vals, grad_norm = batch_train!(solver, env, optimizer, active_q, target_q, s_batch, a_batch, r_batch, sp_batch, done_batch, weights)
    update_priorities!(replay, indices, td_vals)
    return loss_val, td_vals, grad_norm
end

# for RNNs
function batch_train!(solver::DeepQLearningSolver,
                      env::AbstractEnvironment,
                      optimizer, 
                      active_q, 
                      target_q,
                      replay::EpisodeReplayBuffer)
    s_batch, a_batch, r_batch, sp_batch, done_batch, trace_mask_batch = DeepQLearning.sample(replay)

    s_batch = batch_trajectories(s_batch, solver.trace_length, solver.batch_size)
    a_batch = batch_trajectories(a_batch, solver.trace_length, solver.batch_size)
    r_batch = batch_trajectories(r_batch, solver.trace_length, solver.batch_size)
    sp_batch = batch_trajectories(sp_batch, solver.trace_length, solver.batch_size)
    done_batch = batch_trajectories(done_batch, solver.trace_length, solver.batch_size)
    trace_mask_batch = batch_trajectories(trace_mask_batch, solver.trace_length, solver.batch_size)

    q_values = active_q.(s_batch) # vector of size trace_length n_actions x batch_size
    q_sa = [zeros(eltype(q_values[1]), solver.batch_size) for i=1:solver.trace_length]
    for i=1:solver.trace_length  # there might be a more elegant way of doing this
        for j=1:solver.batch_size
            if a_batch[i][j] != 0
                q_sa[i][j] = q_values[i][a_batch[i][j], j]
            end
        end
    end
    if solver.double_q
        target_q_values = target_q.(sp_batch)
        qp_values = active_q.(sp_batch)
        Flux.reset!(active_q)
        # best_a = argmax.(qp_values, dims=1)
        # q_sp_max = broadcast(getindex, target_q_values, best_a)
        q_sp_max = [vec([target_q_values[j][argmax(qp_values[j][:,i]), i] for i=1:solver.batch_size]) for j=1:solver.trace_length] #XXX find more elegant way to do this
    else
        q_sp_max = vec.(maximum.(target_q.(sp_batch), dims=1))
    end
    q_targets = Vector{eltype(q_sa)}(undef, solver.trace_length)
    for i=1:solver.trace_length
        q_targets[i] = r_batch[i] .+ (1.0 .- done_batch[i]).*discount(env.problem).*q_sp_max[i]
    end
    td_tracked = broadcast((x,y) -> x.*y, trace_mask_batch, q_sa .- q_targets)
    loss_tracked = sum(loss.(td_tracked))/solver.trace_length
    Flux.reset!(active_q)
    Flux.truncate!(active_q)
    Flux.reset!(target_q)
    Flux.truncate!(target_q)
    loss_val = Flux.data(loss_tracked)
    td_vals = Flux.data(td_tracked)
    Flux.back!(loss_tracked)
    grad_norm = globalnorm(params(active_q))
    optimizer()
    return loss_val, td_vals, grad_norm
end
