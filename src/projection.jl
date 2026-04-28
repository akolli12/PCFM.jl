# #  projection.jl — AbstractProjectionSolver interface for PCFM
# #
# #  Key structure: the constraint Jacobian is BLOCK-DIAGONAL

# using Optimization, OptimizationOptimJL, ForwardDiff
# using ADTypes, DifferentiationInterface
# abstract type AbstractProjectionSolver end

# # ────────────────────────────────────────────────────────────
# #  N-dimensional helpers
# #  4D: (nx, nt, channels, batch)     → 1D spatial
# #  5D: (sx, sy, nt, channels, batch) → 2D spatial
# # ────────────────────────────────────────────────────────────

# function get_array_layout(Z)
#     nd = ndims(Z)
#     if nd == 4
#         return (nt=size(Z,2), nc=size(Z,3), nb=size(Z,4))
#     elseif nd == 5
#         return (nt=size(Z,3), nc=size(Z,4), nb=size(Z,5))
#     else
#         error("Unsupported array rank $nd")
#     end
# end

# function get_slice(Z, k, c, b)
#     ndims(Z) == 4 ? (@view Z[:, k, c, b]) : (@view Z[:, :, k, c, b])
# end

# function set_slice!(Z, k, c, b, vals)
#     ndims(Z) == 4 ? (Z[:, k, c, b] .= vals) : (Z[:, :, k, c, b] .= vals)
# end

# function n_spatial(Z)
#     ndims(Z) == 4 ? size(Z, 1) : size(Z, 1) * size(Z, 2)
# end

# # Unconstrained

# struct NoOpSolver <: AbstractProjectionSolver end

# function solve_projection(::NoOpSolver, x, constraint_data)
#     return x
# end

# # Analytic IC - linear baseline

# struct AnalyticICProjectionSolver <: AbstractProjectionSolver end

# function solve_projection(::AnalyticICProjectionSolver, Z_hat, constraint_data)
#     Z_proj = copy(Z_hat)
#     Z_proj[:, 1:1, :, :] .= constraint_data.u_0_ic_matrix
#     return Z_proj
# end

# # Analytic Energy - nonlinear, closed-form sphere projection

# struct AnalyticEnergyProjectionSolver <: AbstractProjectionSolver end

# function solve_projection(::AnalyticEnergyProjectionSolver, Z_hat, constraint_data)
#     nx, nt, nc, nb = size(Z_hat)
#     dx = constraint_data.dx
#     E0 = sum(abs2, constraint_data.u_0_ic_vec) * dx
#     Z_proj = copy(Z_hat)
#     for b in 1:nb, c in 1:nc, k in 1:nt
#         slice = @view Z_proj[:, k, c, b]
#         Ek = sum(abs2, slice) * dx
#         if Ek > 0
#             slice .*= sqrt(E0 / Ek)
#         end
#     end
#     return Z_proj
# end

# # Analytic IC + Energy

# struct AnalyticICEnergyProjectionSolver <: AbstractProjectionSolver end

# function solve_projection(::AnalyticICEnergyProjectionSolver, Z_hat, constraint_data)
#     nx, nt, nc, nb = size(Z_hat)
#     dx = constraint_data.dx
#     E0 = sum(abs2, constraint_data.u_0_ic_vec) * dx
#     Z_proj = copy(Z_hat)
#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= constraint_data.u_0_ic_vec
#         for k in 2:nt
#             slice = @view Z_proj[:, k, c, b]
#             Ek = sum(abs2, slice) * dx
#             if Ek > 0
#                 slice .*= sqrt(E0 / Ek)
#             end
#         end
#     end
#     return Z_proj
# end

# # Analytic Mass Conservation (Eq 10 from paper: ∫u dx = 0)

# struct AnalyticMassProjectionSolver <: AbstractProjectionSolver end

# function solve_projection(::AnalyticMassProjectionSolver, Z_hat, constraint_data)
#     nx, nt, nc, nb = size(Z_hat)
#     dx = constraint_data.dx
#     Z_proj = copy(Z_hat)
#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= constraint_data.u_0_ic_vec
#         for k in 2:nt
#             slice = @view Z_proj[:, k, c, b]
#             mass_k = sum(slice) * dx
#             slice .-= mass_k / (nx * dx)
#         end
#     end
#     return Z_proj
# end

# # Analytic IC + Mass

# struct AnalyticICMassProjectionSolver <: AbstractProjectionSolver end

# function solve_projection(::AnalyticICMassProjectionSolver, Z_hat, constraint_data)
#     nx, nt, nc, nb = size(Z_hat)
#     dx = constraint_data.dx
#     Z_proj = copy(Z_hat)
#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= constraint_data.u_0_ic_vec
#         for k in 2:nt
#             slice = @view Z_proj[:, k, c, b]
#             mass_k = sum(slice) * dx
#             slice .-= mass_k / (nx * dx)
#         end
#     end
#     return Z_proj
# end

# # Optimization.jl — LBFGS penalty energy
# #     Same constraint as #2 but solved numerically

# struct PenaltyLBFGSEnergyProjectionSolver{T} <: AbstractProjectionSolver
#     penalty::T
# end
# PenaltyLBFGSEnergyProjectionSolver(; penalty=1.0f4) = PenaltyLBFGSEnergyProjectionSolver(penalty)

# function solve_projection(solver::PenaltyLBFGSEnergyProjectionSolver, Z_hat, constraint_data)
#     nx, nt, nc, nb = size(Z_hat)
#     dx = constraint_data.dx
#     E0 = sum(abs2, constraint_data.u_0_ic_vec) * dx
#     λ = solver.penalty
#     Z_proj = copy(Z_hat)

#     function penalised_loss(u_k, p)
#         u_hat_k = p[1]
#         obj = sum(abs2, u_k .- u_hat_k)
#         energy_viol = sum(abs2, u_k) * dx - E0
#         return obj + λ * energy_viol^2
#     end

#     opt_func = OptimizationFunction(penalised_loss, AutoForwardDiff())

#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= constraint_data.u_0_ic_vec
#         for k in 2:nt
#             u_hat_k = Z_proj[:, k, c, b]
#             u0 = copy(u_hat_k)
#             prob = OptimizationProblem(opt_func, u0, (u_hat_k,))
#             sol = solve(prob, OptimizationOptimJL.LBFGS())
#             Z_proj[:, k, c, b] .= sol.u
#         end
#     end
#     return Z_proj
# end

# # Optimization.jl — Interior Point energy
# #     Same constraint as #2

# struct IPEnergyProjectionSolver <: AbstractProjectionSolver end

# function _ip_energy_loss(u_k, p)
#     u_hat_k = p[1]
#     return sum(abs2, u_k .- u_hat_k)
# end

# function _ip_energy_cons!(res, u_k, p)
#     E0 = p[2]
#     dx = p[3]
#     res[1] = sum(abs2, u_k) * dx - E0
#     return nothing
# end


# function solve_projection(::IPEnergyProjectionSolver, Z_hat, cdata)
#     nx, nt, nc, nb = size(Z_hat)
#     dx = cdata.dx
#     E0 = sum(abs2, cdata.u_0_ic_vec) * dx
#     Z_proj = copy(Z_hat)

#     # Use ForwardDiff for both the inner (gradient) and outer (Hessian) loops
#     ad_type = DifferentiationInterface.SecondOrder(AutoForwardDiff(), AutoForwardDiff())

#     # 2. Build the function with the explicit SecondOrder AD
#     opt_func = OptimizationFunction(
#         _ip_energy_loss, 
#         ad_type; 
#         cons = _ip_energy_cons!
#     )
#     # Build OptimizationFunction once with explicit constraint
#     # opt_func = OptimizationFunction(
#     #     _ip_energy_loss,
#     #     Optimization.AutoForwardDiff();
#     #     cons = _ip_energy_cons!
#     # )

#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec

#         for k in 2:nt
#             # Convert to Float64 to avoid Optim.jl type bug
#             u_hat_k = Float64.(Z_proj[:, k, c, b])
#             u0 = copy(u_hat_k)
#             p = (u_hat_k, Float64(E0), Float64(dx))

#             prob = OptimizationProblem(
#                 opt_func, u0, p;
#                 lcons = [0.0],    # equality: 0 ≤ h ≤ 0
#                 ucons = [0.0]
#             )
#             sol = solve(prob, OptimizationOptimJL.IPNewton())
#             Z_proj[:, k, c, b] .= Float32.(sol.u)
#         end
#     end
#     return Z_proj
# end

# # Optimization.jl — LBFGS penalty mass (numerical baseline)
# #     Same constraint as #4 but solved numerically

# struct PenaltyLBFGSMassProjectionSolver{T} <: AbstractProjectionSolver
#     penalty::T
# end
# PenaltyLBFGSMassProjectionSolver(; penalty=1.0f4) = PenaltyLBFGSMassProjectionSolver(penalty)

# function solve_projection(solver::PenaltyLBFGSMassProjectionSolver, Z_hat, constraint_data)
#     nx, nt, nc, nb = size(Z_hat)
#     dx = constraint_data.dx
#     λ = solver.penalty
#     Z_proj = copy(Z_hat)

#     function penalised_loss(u_k, p)
#         u_hat_k = p[1]
#         obj = sum(abs2, u_k .- u_hat_k)
#         mass_viol = sum(u_k) * dx
#         return obj + λ * mass_viol^2
#     end

#     opt_func = OptimizationFunction(penalised_loss, AutoForwardDiff())

#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= constraint_data.u_0_ic_vec
#         for k in 2:nt
#             u_hat_k = Z_proj[:, k, c, b]
#             u0 = copy(u_hat_k)
#             prob = OptimizationProblem(opt_func, u0, (u_hat_k,))
#             sol = solve(prob, OptimizationOptimJL.LBFGS())
#             Z_proj[:, k, c, b] .= sol.u
#         end
#     end
#     return Z_proj
# end

# # Optimization.jl — IP mass (numerical baseline)
# #     Same constraint as #4 but solved numerically

# struct IPMassProjectionSolver <: AbstractProjectionSolver end

# function _ip_mass_loss(u_k, p)
#     u_hat_k = p[1]
#     return sum(abs2, u_k .- u_hat_k)
# end

# function _ip_mass_cons!(res, u_k, p)
#     dx = p[2]
#     res[1] = sum(u_k) * dx
#     return nothing
# end

# function solve_projection(::IPMassProjectionSolver, Z_hat, cdata)
#     nx, nt, nc, nb = size(Z_hat)
#     dx = cdata.dx
#     Z_proj = copy(Z_hat)

#     # Use ForwardDiff for both the inner (gradient) and outer (Hessian) loops
#     ad_type = DifferentiationInterface.SecondOrder(AutoForwardDiff(), AutoForwardDiff())

#     # 2. Build the function with the explicit SecondOrder AD
#     opt_func = OptimizationFunction(
#         _ip_mass_loss, 
#         ad_type; 
#         cons = _ip_mass_cons!
#     )

#     # opt_func = OptimizationFunction(
#     #     _ip_mass_loss,
#     #     Optimization.AutoForwardDiff();
#     #     cons = _ip_mass_cons!
#     # )

#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec

#         for k in 2:nt
#             u_hat_k = Float64.(Z_proj[:, k, c, b])
#             u0 = copy(u_hat_k)
#             p = (u_hat_k, Float64(dx))

#             prob = OptimizationProblem(
#                 opt_func, u0, p;
#                 lcons = [0.0],
#                 ucons = [0.0]
#             )
#             sol = solve(prob, OptimizationOptimJL.IPNewton())
#             Z_proj[:, k, c, b] .= Float32.(sol.u)
#         end
#     end
#     return Z_proj
# end

# # ════════════════════════════════════════════════════════════
# #  EQUATION 14 — Fisher-KPP: ∂u/∂t = ν∂²u/∂x² + ρu(1-u)
# #
# #  Integrated conservation law:
# #    M_{k+1} = M_k + Δt · [ρ Σᵢ u_k[i](1-u_k[i])Δx + g_L(k) - g_R(k)]
# #
# #  The source term u(1-u) is NONLINEAR — no closed-form projection.
# #  We freeze u_k, compute the target mass M_{k+1}, then optimize
# #  u_{k+1} so its mass matches the target.
# # ════════════════════════════════════════════════════════════

# struct FisherKPPSolver{T} <: AbstractProjectionSolver
#     penalty::T
#     rho::Float32
# end
# FisherKPPSolver(; penalty=1.0f4, rho=1.0f0) = FisherKPPSolver(penalty, rho)

# function solve_projection(solver::FisherKPPSolver, Z_hat, cdata)
#     nx, nt, nc, nb = size(Z_hat)
#     dx      = cdata.dx
#     dt_phys = cdata.dt_physics
#     g_L     = cdata.g_L
#     g_R     = cdata.g_R
#     ρ       = solver.rho
#     λ       = solver.penalty
#     Z_proj  = copy(Z_hat)

#     function penalised_loss(u_next, p)
#         u_hat_next, M_target, _dx = p
#         obj = sum(abs2, u_next .- u_hat_next)
#         M_next = sum(u_next) * _dx
#         return obj + λ * (M_next - M_target)^2
#     end

#     opt_func = OptimizationFunction(penalised_loss, AutoForwardDiff())

#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec

#         for k in 1:(nt - 1)
#             u_k = Z_proj[:, k, c, b]

#             # Current mass
#             M_k = sum(u_k) * dx
#             # Source: ρ ∫u(1-u)dx ≈ ρ Σ u[i](1-u[i]) Δx
#             source = ρ * sum(u_k[i] * (1.0f0 - u_k[i]) for i in 1:nx) * dx
#             # Boundary flux
#             flux = 0 #g_L[k] - g_R[k] = 0 since Neumann (no-flux) boundary conditions
#             # Target mass for next timestep
#             M_target = M_k + dt_phys * (source + flux)

#             u_hat_next = Z_proj[:, k+1, c, b]
#             u0 = copy(u_hat_next)
#             prob = OptimizationProblem(opt_func, u0,
#                 (u_hat_next, Float32(M_target), dx))
#             sol = solve(prob, OptimizationOptimJL.LBFGS())
#             Z_proj[:, k+1, c, b] .= sol.u
#         end
#     end
#     return Z_proj
# end

# # ════════════════════════════════════════════════════════════
# #  B2 — Navier-Stokes Vorticity: ∂w/∂t + u·∇w = νΔw + f
# #
# #  Under periodic BCs, all boundary integrals vanish:
# #    ∫w(x,t)dx = ∫w(x,0)dx = W₀,  ∀t
# #
# #  This is LINEAR (same as heat mass but target = W₀ ≠ 0).
# #  Analytic projection: shift each timestep by a constant.
# # ════════════════════════════════════════════════════════════

# # --- Analytic version ---

# struct NSVorticityAnalyticSolver <: AbstractProjectionSolver end

# function solve_projection(::NSVorticityAnalyticSolver, Z_hat, cdata)
#     layout = get_array_layout(Z_hat) #nx, nt, nc, nb = size(Z_hat)
#     dx = cdata.dx
#     W0 = cdata.M0   # ∫w(x,0)dx
#     Z_proj = copy(Z_hat)
#     for b in 1:nb, c in 1:nc
#         set_slice!(Z_proj, 1, c, b, cdata.u_0_ic) #Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec
#         for k in 2:nt
#             slice = get_slice(Z_proj, k, c, b) #slice = @view Z_proj[:, k, c, b]
#             W_k = sum(slice) * dx
#             # Shift: ∫(w - c)dx = W₀  →  c = (W_k - W₀)/(nx·dx)
#             slice .-= (W_k - W0) / (nx * dx)
#         end
#     end
#     return Z_proj
# end

# # --- LBFGS version ---

# struct NSVorticityLBFGSSolver{T} <: AbstractProjectionSolver
#     penalty::T
# end
# NSVorticityLBFGSSolver(; penalty=1.0f4) = NSVorticityLBFGSSolver(penalty)

# function solve_projection(solver::NSVorticityLBFGSSolver, Z_hat, cdata)
#     nx, nt, nc, nb = size(Z_hat)
#     dx = cdata.dx
#     W0 = cdata.M0
#     λ  = solver.penalty
#     Z_proj = copy(Z_hat)

#     function penalised_loss(w_k, p)
#         w_hat_k, _dx, _W0 = p
#         obj = sum(abs2, w_k .- w_hat_k)
#         W_k = sum(w_k) * _dx
#         return obj + λ * (W_k - _W0)^2
#     end

#     opt_func = OptimizationFunction(penalised_loss, AutoForwardDiff())

#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec
#         for k in 2:nt
#             w_hat_k = Z_proj[:, k, c, b]
#             u0 = copy(w_hat_k)
#             prob = OptimizationProblem(opt_func, u0, (w_hat_k, dx, W0))
#             sol = solve(prob, OptimizationOptimJL.LBFGS())
#             Z_proj[:, k, c, b] .= sol.u
#         end
#     end
#     return Z_proj
# end

# # ════════════════════════════════════════════════════════════
# #  B4 — Burgers: ∂u/∂t + ½∂(u²)/∂x = 0
# #
# #  Integrated conservation law:
# #    d/dt ∫u dx = -½[u(1,t)² - u(0,t)²]
# #
# #  Two constraints per timestep:
# #    (a) u(1)² = u(0)²       (flux balance at boundaries)
# #    (b) M_{k+1} = M_k + Δt·[-½(u_k(1)² - u_k(0)²)]   (mass evolution)
# #
# #  Both are NONLINEAR (quadratic in u at boundaries).
# #  "Highly sensitive due to shock formation" — paper B4.
# # ════════════════════════════════════════════════════════════

# struct BurgersConservationSolver{T} <: AbstractProjectionSolver
#     penalty::T
# end
# BurgersConservationSolver(; penalty=1.0f4) = BurgersConservationSolver(penalty)

# function solve_projection(solver::BurgersConservationSolver, Z_hat, cdata)
#     nx, nt, nc, nb = size(Z_hat)
#     dx      = cdata.dx
#     dt_phys = cdata.dt_physics
#     λ       = solver.penalty
#     Z_proj  = copy(Z_hat)

#     function penalised_loss(u_k, p)
#         u_hat_k, M_target, _dx = p
#         obj = sum(abs2, u_k .- u_hat_k)
#         # Constraint (a): flux balance u(1)² = u(0)²
#         flux_imbalance = u_k[end]^2 - u_k[1]^2
#         obj += λ * flux_imbalance^2
#         # Constraint (b): mass = target
#         M_k = sum(u_k) * _dx
#         obj += λ * (M_k - M_target)^2
#         return obj
#     end

#     opt_func = OptimizationFunction(penalised_loss, AutoForwardDiff())

#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec

#         for k in 1:(nt - 1)
#             u_prev = Z_proj[:, k, c, b]
#             M_prev = sum(u_prev) * dx
#             flux = -0.5f0 * (u_prev[end]^2 - u_prev[1]^2)
#             M_target = M_prev + dt_phys * flux

#             u_hat_next = Z_proj[:, k+1, c, b]
#             u0 = copy(u_hat_next)
#             prob = OptimizationProblem(opt_func, u0,
#                 (u_hat_next, Float32(M_target), dx))
#             sol = solve(prob, OptimizationOptimJL.LBFGS())
#             Z_proj[:, k+1, c, b] .= sol.u
#         end
#     end
#     return Z_proj
# end

# # ════════════════════════════════════════════════════════════
# #  Interior-Point solvers for all four benchmarks
# #
# #  IPNewton handles constraints EXPLICITLY via lcons/ucons
# #  instead of penalty. Uses Float64 to avoid Optim.jl bug.
# #
# #  Compared to LBFGS+penalty:
# #    - Exact constraint satisfaction (not approximate)
# #    - Needs Hessians (slower per iteration)
# #    - Same family as MadNLP (partner's GPU backend)
# # ════════════════════════════════════════════════════════════

# # ────────────────────────────────────────────────────────────
# #  Eq 14 — Fisher-KPP via Interior-Point
# #
# #  Constraint: M_{k+1} = M_k + Δt·[ρ∫u_k(1-u_k)dx + g_L - g_R]
# #  This is enforced as: Σ u_{k+1}[i]·Δx - M_target = 0
# #
# #  The constraint itself (on u_{k+1}) is LINEAR in u_{k+1}.
# #  The nonlinearity is in computing M_target from u_k.
# # ────────────────────────────────────────────────────────────

# struct FisherKPPIPNewtonSolver <: AbstractProjectionSolver
#     rho::Float32
# end
# FisherKPPIPNewtonSolver(; rho=1.0f0) = FisherKPPIPNewtonSolver(rho)

# # Loss: min ||u_{k+1} - û_{k+1}||²
# function _fisher_ip_loss(u_next, p)
#     u_hat_next = p[1]
#     return sum(abs2, u_next .- u_hat_next)
# end

# # Constraint: Σ u_{k+1}·Δx = M_target  →  Σu·dx - M_target = 0
# function _fisher_ip_cons!(res, u_next, p)
#     M_target = p[2]
#     _dx = p[3]
#     res[1] = sum(u_next) * _dx - M_target
#     return nothing
# end

# function solve_projection(solver::FisherKPPIPNewtonSolver, Z_hat, cdata)
#     nx, nt, nc, nb = size(Z_hat)
#     dx      = cdata.dx
#     dt_phys = cdata.dt_physics
#     g_L     = cdata.g_L
#     g_R     = cdata.g_R
#     ρ       = solver.rho
#     Z_proj  = copy(Z_hat)

#     ad_type = DifferentiationInterface.SecondOrder(AutoForwardDiff(), AutoForwardDiff())

#     opt_func = OptimizationFunction(
#         _fisher_ip_loss,
#         ad_type;
#         cons = _fisher_ip_cons!
#     )

#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec

#         for k in 1:(nt - 1)
#             u_k = Z_proj[:, k, c, b]

#             # Compute target mass from Fisher-KPP conservation law
#             M_k = sum(u_k) * dx
#             source = ρ * sum(u_k[i] * (1.0f0 - u_k[i]) for i in 1:nx) * dx
#             flux = 0 # g_L[k] - g_R[k] = 0 because Neumann (no-flux) boundary conditions
#             M_target = M_k + dt_phys * (source + flux)

#             # Convert to Float64 for IPNewton
#             u_hat_next = Float64.(Z_proj[:, k+1, c, b])
#             u0 = copy(u_hat_next)
#             p = (u_hat_next, Float64(M_target), Float64(dx))

#             prob = OptimizationProblem(
#                 opt_func, u0, p;
#                 lcons = [0.0],
#                 ucons = [0.0]
#             )
#             sol = solve(prob, OptimizationOptimJL.IPNewton())
#             Z_proj[:, k+1, c, b] .= Float32.(sol.u)
#         end
#     end
#     return Z_proj
# end

# # ────────────────────────────────────────────────────────────
# #  B2 — NS Vorticity via Interior-Point
# #
# #  Constraint: ∫w dx = W₀ at each timestep
# #  Enforced as: Σ w_k[i]·Δx - W₀ = 0
# #  This is LINEAR in w_k.
# # ────────────────────────────────────────────────────────────

# struct NSVorticityIPNewtonSolver <: AbstractProjectionSolver end

# function _ns_ip_loss(w_k, p)
#     w_hat_k = p[1]
#     return sum(abs2, w_k .- w_hat_k)
# end

# function _ns_ip_cons!(res, w_k, p)
#     W0 = p[2]
#     _dx = p[3]
#     res[1] = sum(w_k) * _dx - W0
#     return nothing
# end

# function solve_projection(::NSVorticityIPNewtonSolver, Z_hat, cdata)
#     nx, nt, nc, nb = size(Z_hat)
#     dx = cdata.dx
#     W0 = cdata.M0
#     Z_proj = copy(Z_hat)

#     ad_type = DifferentiationInterface.SecondOrder(AutoForwardDiff(), AutoForwardDiff())

#     opt_func = OptimizationFunction(
#         _ns_ip_loss,
#         ad_type;
#         cons = _ns_ip_cons!
#     )

#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec

#         for k in 2:nt
#             w_hat_k = Float64.(Z_proj[:, k, c, b])
#             u0 = copy(w_hat_k)
#             p = (w_hat_k, Float64(W0), Float64(dx))

#             prob = OptimizationProblem(
#                 opt_func, u0, p;
#                 lcons = [0.0],
#                 ucons = [0.0]
#             )
#             sol = solve(prob, OptimizationOptimJL.IPNewton())
#             Z_proj[:, k, c, b] .= Float32.(sol.u)
#         end
#     end
#     return Z_proj
# end

# # ────────────────────────────────────────────────────────────
# #  B4 — Burgers via Interior-Point
# #
# #  Two constraints per timestep:
# #    (a) u(1)² - u(0)² = 0         [flux balance]
# #    (b) Σ u·Δx - M_target = 0     [mass evolution]
# #
# #  Constraint (a) is NONLINEAR (quadratic in boundary values).
# #  This is the hardest case — "highly sensitive due to shock
# #  formation." IPNewton handles both simultaneously as
# #  explicit equality constraints.
# # ────────────────────────────────────────────────────────────

# struct BurgersIPNewtonSolver <: AbstractProjectionSolver end

# function _burgers_ip_loss(u_k, p)
#     u_hat_k = p[1]
#     return sum(abs2, u_k .- u_hat_k)
# end

# # Two constraints: flux balance + mass target
# function _burgers_ip_cons!(res, u_k, p)
#     M_target = p[2]
#     _dx = p[3]
#     # Constraint 1: u(1)² = u(0)²  →  u(end)² - u(1)² = 0
#     res[1] = u_k[end]^2 - u_k[1]^2
#     # Constraint 2: Σu·dx = M_target  →  Σu·dx - M_target = 0
#     res[2] = sum(u_k) * _dx - M_target
#     return nothing
# end

# function solve_projection(::BurgersIPNewtonSolver, Z_hat, cdata)
#     nx, nt, nc, nb = size(Z_hat)
#     dx      = cdata.dx
#     dt_physics = cdata.dt_physics
#     Z_proj  = copy(Z_hat)

#     # Two equality constraints: both must = 0
#     ad_type = DifferentiationInterface.SecondOrder(AutoForwardDiff(), AutoForwardDiff())

#     opt_func = OptimizationFunction(
#         _burgers_ip_loss,
#         ad_type;
#         cons = _burgers_ip_cons!
#     )

#     for b in 1:nb, c in 1:nc
#         Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec

#         for k in 1:(nt - 1)
#             u_prev = Z_proj[:, k, c, b]

#             # Compute target mass from Burgers conservation law
#             M_prev = sum(u_prev) * dx
#             flux = -0.5f0 * (u_prev[end]^2 - u_prev[1]^2)
#             M_target = M_prev + dt_physics * flux

#             u_hat_next = Float64.(Z_proj[:, k+1, c, b])
#             u0 = copy(u_hat_next)
#             p = (u_hat_next, Float64(M_target), Float64(dx))

#             prob = OptimizationProblem(
#                 opt_func, u0, p;
#                 lcons = [0.0, 0.0],   # two equality constraints
#                 ucons = [0.0, 0.0]
#             )
#             sol = solve(prob, OptimizationOptimJL.IPNewton())
#             Z_proj[:, k+1, c, b] .= Float32.(sol.u)
#         end
#     end
#     return Z_proj
# end

# # Constraint data factory

# function make_constraint_data(u_0_ic, nx_or_spatial, nt, n_samples;
#                                dx = nothing, #Float32(2π / nx),
#                                dt_physics = Float32(1.0 / (nt - 1)),
#                                g_L = nothing,
#                                g_R = nothing)
#     # Accept either a vector or a 2D array as IC
#     ic = Float32.(u_0_ic)
    
#     # Compute dx if not provided
#     if dx === nothing
#         dx = Float32(2π / (nx_or_spatial isa Tuple ? prod(nx_or_spatial) : nx_or_spatial))
#     end
    
#     M0 = sum(ic) * dx
    
#     _g_L = g_L === nothing ? zeros(Float32, nt) : g_L
#     _g_R = g_R === nothing ? zeros(Float32, nt) : g_R

#     return (
#         u_0_ic    = ic,
#         dx        = dx,
#         dt_physics   = dt_physics,
#         nt        = nt,
#         M0        = M0,
#         g_L       = _g_L,
#         g_R       = _g_R,
#     )
# end

#  projection.jl — AbstractProjectionSolver interface for PCFM

using Optimization, OptimizationOptimJL, ForwardDiff
using ADTypes, DifferentiationInterface
abstract type AbstractProjectionSolver end

# N-dimensional helpers  - for NS 2D

function get_array_layout(Z)
    nd = ndims(Z)
    if nd == 4
        return (nt=size(Z,2), nc=size(Z,3), nb=size(Z,4))
    elseif nd == 5
        return (nt=size(Z,3), nc=size(Z,4), nb=size(Z,5))
    else
        error("Unsupported array rank $nd")
    end
end

function get_slice(Z, k, c, b)
    ndims(Z) == 4 ? (@view Z[:, k, c, b]) : (@view Z[:, :, k, c, b])
end

function set_slice!(Z, k, c, b, vals)
    ndims(Z) == 4 ? (Z[:, k, c, b] .= vals) : (Z[:, :, k, c, b] .= vals)
end

function n_spatial(Z)
    ndims(Z) == 4 ? size(Z, 1) : size(Z, 1) * size(Z, 2)
end

# 1D SOLVERS

struct NoOpSolver <: AbstractProjectionSolver end

function solve_projection(::NoOpSolver, x, constraint_data)
    return x
end

struct AnalyticICProjectionSolver <: AbstractProjectionSolver end

function solve_projection(::AnalyticICProjectionSolver, Z_hat, constraint_data)
    Z_proj = copy(Z_hat)
    Z_proj[:, 1:1, :, :] .= constraint_data.u_0_ic_matrix
    return Z_proj
end

struct AnalyticEnergyProjectionSolver <: AbstractProjectionSolver end

function solve_projection(::AnalyticEnergyProjectionSolver, Z_hat, constraint_data)
    nx, nt, nc, nb = size(Z_hat)
    dx = constraint_data.dx
    E0 = sum(abs2, constraint_data.u_0_ic_vec) * dx
    Z_proj = copy(Z_hat)
    for b in 1:nb, c in 1:nc, k in 1:nt
        slice = @view Z_proj[:, k, c, b]
        Ek = sum(abs2, slice) * dx
        if Ek > 0
            slice .*= sqrt(E0 / Ek)
        end
    end
    return Z_proj
end

struct AnalyticICEnergyProjectionSolver <: AbstractProjectionSolver end

function solve_projection(::AnalyticICEnergyProjectionSolver, Z_hat, constraint_data)
    nx, nt, nc, nb = size(Z_hat)
    dx = constraint_data.dx
    E0 = sum(abs2, constraint_data.u_0_ic_vec) * dx
    Z_proj = copy(Z_hat)
    for b in 1:nb, c in 1:nc
        Z_proj[:, 1, c, b] .= constraint_data.u_0_ic_vec
        for k in 2:nt
            slice = @view Z_proj[:, k, c, b]
            Ek = sum(abs2, slice) * dx
            if Ek > 0
                slice .*= sqrt(E0 / Ek)
            end
        end
    end
    return Z_proj
end

struct AnalyticMassProjectionSolver <: AbstractProjectionSolver end

function solve_projection(::AnalyticMassProjectionSolver, Z_hat, constraint_data)
    nx, nt, nc, nb = size(Z_hat)
    dx = constraint_data.dx
    Z_proj = copy(Z_hat)
    for b in 1:nb, c in 1:nc
        Z_proj[:, 1, c, b] .= constraint_data.u_0_ic_vec
        for k in 2:nt
            slice = @view Z_proj[:, k, c, b]
            mass_k = sum(slice) * dx
            slice .-= mass_k / (nx * dx)
        end
    end
    return Z_proj
end

struct AnalyticICMassProjectionSolver <: AbstractProjectionSolver end

function solve_projection(::AnalyticICMassProjectionSolver, Z_hat, constraint_data)
    nx, nt, nc, nb = size(Z_hat)
    dx = constraint_data.dx
    Z_proj = copy(Z_hat)
    for b in 1:nb, c in 1:nc
        Z_proj[:, 1, c, b] .= constraint_data.u_0_ic_vec
        for k in 2:nt
            slice = @view Z_proj[:, k, c, b]
            mass_k = sum(slice) * dx
            slice .-= mass_k / (nx * dx)
        end
    end
    return Z_proj
end

# LBFGS + IP - still 1D

struct PenaltyLBFGSEnergyProjectionSolver{T} <: AbstractProjectionSolver
    penalty::T
end
PenaltyLBFGSEnergyProjectionSolver(; penalty=1.0f4) = PenaltyLBFGSEnergyProjectionSolver(penalty)

function solve_projection(solver::PenaltyLBFGSEnergyProjectionSolver, Z_hat, constraint_data)
    nx, nt, nc, nb = size(Z_hat)
    dx = constraint_data.dx
    E0 = sum(abs2, constraint_data.u_0_ic_vec) * dx
    λ = solver.penalty
    Z_proj = copy(Z_hat)

    function penalised_loss(u_k, p)
        u_hat_k = p[1]
        obj = sum(abs2, u_k .- u_hat_k)
        energy_viol = sum(abs2, u_k) * dx - E0
        return obj + λ * energy_viol^2
    end

    opt_func = OptimizationFunction(penalised_loss, AutoForwardDiff())

    for b in 1:nb, c in 1:nc
        Z_proj[:, 1, c, b] .= constraint_data.u_0_ic_vec
        for k in 2:nt
            u_hat_k = Z_proj[:, k, c, b]
            u0 = copy(u_hat_k)
            prob = OptimizationProblem(opt_func, u0, (u_hat_k,))
            sol = solve(prob, OptimizationOptimJL.LBFGS())
            Z_proj[:, k, c, b] .= sol.u
        end
    end
    return Z_proj
end

struct IPEnergyProjectionSolver <: AbstractProjectionSolver end

function _ip_energy_loss(u_k, p)
    u_hat_k = p[1]
    return sum(abs2, u_k .- u_hat_k)
end

function _ip_energy_cons!(res, u_k, p)
    E0 = p[2]
    dx = p[3]
    res[1] = sum(abs2, u_k) * dx - E0
    return nothing
end

function solve_projection(::IPEnergyProjectionSolver, Z_hat, cdata)
    nx, nt, nc, nb = size(Z_hat)
    dx = cdata.dx
    E0 = sum(abs2, cdata.u_0_ic_vec) * dx
    Z_proj = copy(Z_hat)

    ad_type = DifferentiationInterface.SecondOrder(AutoForwardDiff(), AutoForwardDiff())
    opt_func = OptimizationFunction(_ip_energy_loss, ad_type; cons = _ip_energy_cons!)

    for b in 1:nb, c in 1:nc
        Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec
        for k in 2:nt
            u_hat_k = Float64.(Z_proj[:, k, c, b])
            u0 = copy(u_hat_k)
            p = (u_hat_k, Float64(E0), Float64(dx))
            prob = OptimizationProblem(opt_func, u0, p; lcons = [0.0], ucons = [0.0])
            sol = solve(prob, OptimizationOptimJL.IPNewton())
            Z_proj[:, k, c, b] .= Float32.(sol.u)
        end
    end
    return Z_proj
end

struct PenaltyLBFGSMassProjectionSolver{T} <: AbstractProjectionSolver
    penalty::T
end
PenaltyLBFGSMassProjectionSolver(; penalty=1.0f4) = PenaltyLBFGSMassProjectionSolver(penalty)

function solve_projection(solver::PenaltyLBFGSMassProjectionSolver, Z_hat, constraint_data)
    nx, nt, nc, nb = size(Z_hat)
    dx = constraint_data.dx
    λ = solver.penalty
    Z_proj = copy(Z_hat)

    function penalised_loss(u_k, p)
        u_hat_k = p[1]
        obj = sum(abs2, u_k .- u_hat_k)
        mass_viol = sum(u_k) * dx
        return obj + λ * mass_viol^2
    end

    opt_func = OptimizationFunction(penalised_loss, AutoForwardDiff())

    for b in 1:nb, c in 1:nc
        Z_proj[:, 1, c, b] .= constraint_data.u_0_ic_vec
        for k in 2:nt
            u_hat_k = Z_proj[:, k, c, b]
            u0 = copy(u_hat_k)
            prob = OptimizationProblem(opt_func, u0, (u_hat_k,))
            sol = solve(prob, OptimizationOptimJL.LBFGS())
            Z_proj[:, k, c, b] .= sol.u
        end
    end
    return Z_proj
end

struct IPMassProjectionSolver <: AbstractProjectionSolver end

function _ip_mass_loss(u_k, p)
    u_hat_k = p[1]
    return sum(abs2, u_k .- u_hat_k)
end

function _ip_mass_cons!(res, u_k, p)
    dx = p[2]
    res[1] = sum(u_k) * dx
    return nothing
end

function solve_projection(::IPMassProjectionSolver, Z_hat, cdata)
    nx, nt, nc, nb = size(Z_hat)
    dx = cdata.dx
    Z_proj = copy(Z_hat)

    ad_type = DifferentiationInterface.SecondOrder(AutoForwardDiff(), AutoForwardDiff())
    opt_func = OptimizationFunction(_ip_mass_loss, ad_type; cons = _ip_mass_cons!)

    for b in 1:nb, c in 1:nc
        Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec
        for k in 2:nt
            u_hat_k = Float64.(Z_proj[:, k, c, b])
            u0 = copy(u_hat_k)
            p = (u_hat_k, Float64(dx))
            prob = OptimizationProblem(opt_func, u0, p; lcons = [0.0], ucons = [0.0])
            sol = solve(prob, OptimizationOptimJL.IPNewton())
            Z_proj[:, k, c, b] .= Float32.(sol.u)
        end
    end
    return Z_proj
end

# RD - 1D

struct RDSolver{T} <: AbstractProjectionSolver
    penalty::T
    rho::Float32
end
RDSolver(; penalty=1.0f4, rho=1.0f0) = RDSolver(penalty, rho)

function solve_projection(solver::RDSolver, Z_hat, cdata)
    nx, nt, nc, nb = size(Z_hat)
    dx      = cdata.dx
    dt_phys = cdata.dt_physics
    ρ       = solver.rho
    λ       = solver.penalty
    Z_proj  = copy(Z_hat)

    function penalised_loss(u_next, p)
        u_hat_next, M_target, _dx = p
        obj = sum(abs2, u_next .- u_hat_next)
        M_next = sum(u_next) * _dx
        return obj + λ * (M_next - M_target)^2
    end

    opt_func = OptimizationFunction(penalised_loss, AutoForwardDiff())

    for b in 1:nb, c in 1:nc
        Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec

        for k in 1:(nt - 1)
            u_k = Z_proj[:, k, c, b]
            M_k = sum(u_k) * dx
            source = ρ * sum(u_k[i] * (1.0f0 - u_k[i]) for i in 1:nx) * dx
            flux = 0
            M_target = M_k + dt_phys * (source + flux)

            u_hat_next = Z_proj[:, k+1, c, b]
            u0 = copy(u_hat_next)
            prob = OptimizationProblem(opt_func, u0,
                (u_hat_next, Float32(M_target), dx))
            sol = solve(prob, OptimizationOptimJL.LBFGS())
            Z_proj[:, k+1, c, b] .= sol.u
        end
    end
    return Z_proj
end

struct RDIPNewtonSolver <: AbstractProjectionSolver
    rho::Float32
end
RDIPNewtonSolver(; rho=1.0f0) = RDIPNewtonSolver(rho)

function _rd_ip_loss(u_next, p)
    u_hat_next = p[1]
    return sum(abs2, u_next .- u_hat_next)
end

function _rd_ip_cons!(res, u_next, p)
    M_target = p[2]
    _dx = p[3]
    res[1] = sum(u_next) * _dx - M_target
    return nothing
end

function solve_projection(solver::RDIPNewtonSolver, Z_hat, cdata)
    nx, nt, nc, nb = size(Z_hat)
    dx      = cdata.dx
    dt_phys = cdata.dt_physics
    ρ       = solver.rho
    Z_proj  = copy(Z_hat)

    ad_type = DifferentiationInterface.SecondOrder(AutoForwardDiff(), AutoForwardDiff())
    opt_func = OptimizationFunction(_rd_ip_loss, ad_type; cons = _rd_ip_cons!)

    for b in 1:nb, c in 1:nc
        Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec

        for k in 1:(nt - 1)
            u_k = Z_proj[:, k, c, b]
            M_k = sum(u_k) * dx
            source = ρ * sum(u_k[i] * (1.0f0 - u_k[i]) for i in 1:nx) * dx
            flux = 0
            M_target = M_k + dt_phys * (source + flux)

            u_hat_next = Float64.(Z_proj[:, k+1, c, b])
            u0 = copy(u_hat_next)
            p = (u_hat_next, Float64(M_target), Float64(dx))
            prob = OptimizationProblem(opt_func, u0, p; lcons = [0.0], ucons = [0.0])
            sol = solve(prob, OptimizationOptimJL.IPNewton())
            Z_proj[:, k+1, c, b] .= Float32.(sol.u)
        end
    end
    return Z_proj
end

#  B2 — NS Vorticity: ∫w dx = W₀ - 2D

struct NSVorticityAnalyticSolver <: AbstractProjectionSolver end

function solve_projection(::NSVorticityAnalyticSolver, Z_hat, cdata)
    layout = get_array_layout(Z_hat)
    dx = cdata.dx
    W0 = cdata.M0
    npts = n_spatial(Z_hat)
    Z_proj = copy(Z_hat)
    for b in 1:layout.nb, c in 1:layout.nc
        set_slice!(Z_proj, 1, c, b, cdata.u_0_ic)
        for k in 2:layout.nt
            slice = get_slice(Z_proj, k, c, b)
            W_k = sum(slice) * dx
            slice .-= (W_k - W0) / (npts * dx)
        end
    end
    return Z_proj
end

struct NSVorticityLBFGSSolver{T} <: AbstractProjectionSolver
    penalty::T
end
NSVorticityLBFGSSolver(; penalty=1.0f4) = NSVorticityLBFGSSolver(penalty)

function solve_projection(solver::NSVorticityLBFGSSolver, Z_hat, cdata)
    layout = get_array_layout(Z_hat)
    dx = cdata.dx
    W0 = cdata.M0
    λ  = solver.penalty
    Z_proj = copy(Z_hat)

    function penalised_loss(w_flat, p)
        w_hat_flat, _dx, _W0 = p
        obj = sum(abs2, w_flat .- w_hat_flat)
        W_k = sum(w_flat) * _dx
        return obj + λ * (W_k - _W0)^2
    end

    opt_func = OptimizationFunction(penalised_loss, AutoForwardDiff())

    for b in 1:layout.nb, c in 1:layout.nc
        set_slice!(Z_proj, 1, c, b, cdata.u_0_ic)
        for k in 2:layout.nt
            slice = get_slice(Z_proj, k, c, b)
            w_hat_flat = vec(copy(slice))
            u0 = copy(w_hat_flat)
            prob = OptimizationProblem(opt_func, u0, (w_hat_flat, dx, W0))
            sol = solve(prob, OptimizationOptimJL.LBFGS())
            slice .= reshape(sol.u, size(slice))
        end
    end
    return Z_proj
end

struct NSVorticityIPNewtonSolver <: AbstractProjectionSolver end

function _ns_ip_loss(w_flat, p)
    w_hat_flat = p[1]
    return sum(abs2, w_flat .- w_hat_flat)
end

function _ns_ip_cons!(res, w_flat, p)
    W0 = p[2]
    _dx = p[3]
    res[1] = sum(w_flat) * _dx - W0
    return nothing
end

function solve_projection(::NSVorticityIPNewtonSolver, Z_hat, cdata)
    layout = get_array_layout(Z_hat)
    dx = cdata.dx
    W0 = cdata.M0
    Z_proj = copy(Z_hat)

    ad_type = DifferentiationInterface.SecondOrder(AutoForwardDiff(), AutoForwardDiff())
    opt_func = OptimizationFunction(_ns_ip_loss, ad_type; cons = _ns_ip_cons!)

    for b in 1:layout.nb, c in 1:layout.nc
        set_slice!(Z_proj, 1, c, b, cdata.u_0_ic)
        for k in 2:layout.nt
            slice = get_slice(Z_proj, k, c, b)
            w_hat = Float64.(vec(slice))
            u0 = copy(w_hat)
            p = (w_hat, Float64(W0), Float64(dx))
            prob = OptimizationProblem(opt_func, u0, p; lcons = [0.0], ucons = [0.0])
            sol = solve(prob, OptimizationOptimJL.IPNewton())
            slice .= reshape(Float32.(sol.u), size(slice))
        end
    end
    return Z_proj
end

# Burgers - 1D

struct BurgersConservationSolver{T} <: AbstractProjectionSolver
    penalty::T
end
BurgersConservationSolver(; penalty=1.0f4) = BurgersConservationSolver(penalty)

function solve_projection(solver::BurgersConservationSolver, Z_hat, cdata)
    nx, nt, nc, nb = size(Z_hat)
    dx      = cdata.dx
    dt_phys = cdata.dt_physics
    λ       = solver.penalty
    Z_proj  = copy(Z_hat)

    function penalised_loss(u_k, p)
        u_hat_k, M_target, _dx = p
        obj = sum(abs2, u_k .- u_hat_k)
        flux_imbalance = u_k[end]^2 - u_k[1]^2
        obj += λ * flux_imbalance^2
        M_k = sum(u_k) * _dx
        obj += λ * (M_k - M_target)^2
        return obj
    end

    opt_func = OptimizationFunction(penalised_loss, AutoForwardDiff())

    for b in 1:nb, c in 1:nc
        Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec

        for k in 1:(nt - 1)
            u_prev = Z_proj[:, k, c, b]
            M_prev = sum(u_prev) * dx
            flux = -0.5f0 * (u_prev[end]^2 - u_prev[1]^2)
            M_target = M_prev + dt_phys * flux

            u_hat_next = Z_proj[:, k+1, c, b]
            u0 = copy(u_hat_next)
            prob = OptimizationProblem(opt_func, u0,
                (u_hat_next, Float32(M_target), dx))
            sol = solve(prob, OptimizationOptimJL.LBFGS())
            Z_proj[:, k+1, c, b] .= sol.u
        end
    end
    return Z_proj
end

struct BurgersIPNewtonSolver <: AbstractProjectionSolver end

function _burgers_ip_loss(u_k, p)
    u_hat_k = p[1]
    return sum(abs2, u_k .- u_hat_k)
end

function _burgers_ip_cons!(res, u_k, p)
    M_target = p[2]
    _dx = p[3]
    res[1] = u_k[end]^2 - u_k[1]^2
    res[2] = sum(u_k) * _dx - M_target
    return nothing
end

function solve_projection(::BurgersIPNewtonSolver, Z_hat, cdata)
    nx, nt, nc, nb = size(Z_hat)
    dx      = cdata.dx
    dt_phys = cdata.dt_physics
    Z_proj  = copy(Z_hat)

    ad_type = DifferentiationInterface.SecondOrder(AutoForwardDiff(), AutoForwardDiff())
    opt_func = OptimizationFunction(_burgers_ip_loss, ad_type; cons = _burgers_ip_cons!)

    for b in 1:nb, c in 1:nc
        Z_proj[:, 1, c, b] .= cdata.u_0_ic_vec

        for k in 1:(nt - 1)
            u_prev = Z_proj[:, k, c, b]
            M_prev = sum(u_prev) * dx
            flux = -0.5f0 * (u_prev[end]^2 - u_prev[1]^2)
            M_target = M_prev + dt_phys * flux

            u_hat_next = Float64.(Z_proj[:, k+1, c, b])
            u0 = copy(u_hat_next)
            p = (u_hat_next, Float64(M_target), Float64(dx))
            prob = OptimizationProblem(opt_func, u0, p; lcons = [0.0, 0.0], ucons = [0.0, 0.0])
            sol = solve(prob, OptimizationOptimJL.IPNewton())
            Z_proj[:, k+1, c, b] .= Float32.(sol.u)
        end
    end
    return Z_proj
end

#  Constraint data factory
#
#  Returns BOTH old field names (u_0_ic_vec, u_0_ic_matrix)
#  AND new field name (u_0_ic) so all solvers work.

function make_constraint_data(u_0_ic_input, nx_or_spatial, nt, n_samples;
                               dx = nothing,
                               dt_physics = Float32(1.0 / (nt - 1)),
                               g_L = nothing,
                               g_R = nothing)
    ic = Float32.(u_0_ic_input)

    if dx === nothing
        nx_val = nx_or_spatial isa Tuple ? prod(nx_or_spatial) : nx_or_spatial
        dx = Float32(2π / nx_val)
    end

    M0 = sum(ic) * dx

    _g_L = g_L === nothing ? zeros(Float32, nt) : g_L
    _g_R = g_R === nothing ? zeros(Float32, nt) : g_R

    # For 1D need to build the old matrix format 
    if ndims(ic) == 1
        nx = length(ic)
        ic_matrix = repeat(reshape(ic, nx, 1, 1, 1), 1, 1, 1, n_samples)
    else
        # 2D IC — matrix format not used by NS solvers - placeholder
        ic_matrix = nothing
    end

    return (
        # New field names (used by NS solvers)
        u_0_ic       = ic,
        # Old field names (used by all 1D solvers)
        u_0_ic_vec   = ndims(ic) == 1 ? ic : vec(ic),
        u_0_ic_matrix = ic_matrix,
        # Shared fields
        dx           = dx,
        dt_physics   = dt_physics,
        nt           = nt,
        M0           = M0,
        g_L          = _g_L,
        g_R          = _g_R,
    )
end