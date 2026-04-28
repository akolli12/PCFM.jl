using JLD2, PCFM, Lux, Random, Plots
# Build 2D model matching the checkpoint
s = 64
nt_ns = 50
emb_channels = 32

ffm = FFM(spatial_size=(s, s), nt=nt_ns, emb_channels=emb_channels,
          hidden_channels=64, proj_channels=256,
          n_layers=4, modes=(12, 12, 16), device=cpu_device())
_, st_inf = Lux.setup(Random.default_rng(), ffm.model)

# Load checkpoint
saved = JLD2.load("examples/checkpoints/ffm_ns_checkpoint.jld2")
ps = saved["parameters"]
st = saved["states"]

n_samples = 4
n_steps = 20

# 2D vorticity IC (64×64)
x_grid = Float32.(range(0.0, 1.0, length=s))
u_0_ic = Float32.([sin(2π*x + 2π*y) for x in x_grid, y in x_grid])
dx = Float32(1.0 / s)

cdata = make_constraint_data(u_0_ic, (s, s), nt_ns, n_samples; dx=dx)
W0 = cdata.M0

solvers = [
    ("B2: Vorticity (analytic)", NSVorticityAnalyticSolver()),
    # ("B2: Vorticity (LBFGS)",   NSVorticityLBFGSSolver(penalty=1.0f4)),
    ("B2: Vorticity (IP)", NSVorticityIPNewtonSolver())
]

results = []
for (i, (label, solver)) in enumerate(solvers)
    println("\n[$i] $label …")
    t0 = time()
    # Pass tuple (s,s) instead of integer nx
    samples = sample_pcfm(ffm.model, ps, st_inf, (s, s), nt_ns, emb_channels,
        n_samples, n_steps, solver, cdata; verbose=false)
    dt = time() - t0
    println("  $(round(dt;digits=1)) s")
    push!(results, (label=label, samples=samples, time=dt))
end

function vorticity_violation(samples, W0, dx)
    layout = get_array_layout(samples)
    viols = Float64[]
    for b in 1:layout.nb, c in 1:layout.nc, k in 1:layout.nt
        slice = get_slice(samples, k, c, b)
        push!(viols, abs(sum(slice) * dx - W0))
    end
    return (mean=sum(viols)/length(viols), max=maximum(viols))
end

println("\n" * "=" ^ 60)
for r in results
    vv = vorticity_violation(r.samples, W0, dx)
    println("$(rpad(r.label, 30)) vort_viol=$(round(vv.mean;digits=6))  $(round(r.time;digits=1))s")
end
println("\nDone.")