# Analytically solvable component fixtures, never a competition-case builder.
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
length(ARGS)==3 || error("kind output config required")
kind,output,config_path=ARGS
kind in ("cost_feedback","phase_one") || error("Unknown tiny fixture")
config=JSON.parsefile(config_path);model=Model()
@variable(model,u,Bin);@variable(model,0<=dispatch<=1)
get(config,"scheduling_benders_primal_policy","off")=="cold_online_then_fixed_cost_v1" &&
    set_name(u,"p_on_status[a,1]")
@variable(model,p_rgu[device in ["a"],hour in [1]]>=0)
@constraint(model,dispatch<=u)
@constraint(model,p_rgu["a",1]+dispatch>=1)
kind=="phase_one" && @constraint(model,p_rgu["a",1]<=dispatch)
@objective(model,Max,-0.25*u-0.5*dispatch-3*p_rgu["a",1])
write_scheduling_spool(model,joinpath(output,"scheduling_spool");
    identity=Dict("config"=>config,"input_sha256"=>spool_sha(@__FILE__),"fixture"=>kind))
# For u=0, the first fixture costs 3 and the second is infeasible.
# For u=1, cost=.25+.5p+3(1-p)=3.25-2.5p is minimized at p=1.
atomic_json(joinpath(output,"expected.json"),Dict("objective"=>-0.75,
    "proof"=>"Enumerate binary u; minimize the decreasing affine cost on 0<=dispatch<=u",
    "expected_minimum_rounds"=>kind=="phase_one" ? 3 : 2,"builder_solve_calls"=>0))
