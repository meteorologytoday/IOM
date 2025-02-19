include("EMOM/src/share/LogSystem.jl")
include("EMOM/src/share/PolelikeCoordinate.jl")
include("EMOM/src/models/EMOM/ENGINE_EMOM.jl")
include("EMOM/src/driver/driver_working.jl")
include("EMOM/src/share/CyclicData.jl")

using MPI
using CFTime, Dates
using ArgParse
using TOML

using .PolelikeCoordinate
using .LogSystem
using .CyclicData
function parse_commandline()

    s = ArgParseSettings()

    @add_arg_table s begin

        "--continue-run"
            help = "If this is a continued run"
            action = :store_true


        "--config-file"
            help = "Configuration file."
            arg_type = String
            required = true

        "--atm-forcing"
            help = "Atm forcing file. It should contain: TAUX, TAUY, SWFLX, NSWFLX, VSFLX"
            arg_type = String
            required = true

        "--stop-n"
            help = "Core of the model."
            arg_type = Int64

        "--time-unit"
            help = "Unit of `stop-n`."
            arg_type = String

    end

    return parse_args(s)
end

parsed = parse_commandline()

MPI.Init()
comm = MPI.COMM_WORLD
rank = MPI.Comm_rank(comm)
is_master = rank == 0

config = nothing
if is_master

    config = TOML.parsefile(parsed["config-file"])

    time_unit = Dict(
        "year" => Dates.Year,
        "month" => Dates.Month,
        "day"   => Dates.Day,
    )[parsed["time-unit"]]

    t_simulation = time_unit(parsed["stop-n"])

    Δt = Dates.Second(86400)
    read_restart = parsed["continue-run"]

    cfgmc = config["MODEL_CORE"]
    cfgmm = config["MODEL_MISC"]

    t_start = DateTimeNoLeap(1, 1, 1, 0, 0, 0)
    t_end = t_start + t_simulation

end

coupler_funcs = (

    master_before_model_init = function()

        cdata_var_file_map = Dict()

        for varname in ["TAUX", "TAUY", "SWFLX", "NSWFLX", "VSFLX"]
            cdata_var_file_map[varname] = parsed["atm-forcing"]
        end


        global cdatam = CyclicDataManager(;
            timetype     = getproperty(CFTime, Symbol(cfgmm["timetype"])),
            var_file_map = cdata_var_file_map,
            beg_time     = DateTimeNoLeap( 1, 1, 1),
            end_time     = DateTimeNoLeap( 6, 1, 1),
            align_time   = DateTimeNoLeap( 1, 1, 1),
        )

        global datastream = makeDataContainer(cdatam)

        return read_restart, t_start
    end,

    master_after_model_init! = function(OMMODULE, OMDATA)
            # setup forcing

    end,

    master_before_model_run! = function(OMMODULE, OMDATA)

        global datastream

        t_end_reached = OMDATA.clock.time >= t_end

        if ! t_end_reached

            interpData!(cdatam, OMDATA.clock.time, datastream)
            OMDATA.x2o["SWFLX"]       .= datastream["SWFLX"]
            OMDATA.x2o["NSWFLX"]      .= datastream["NSWFLX"]
            OMDATA.x2o["VSFLX"]       .= datastream["VSFLX"]
            OMDATA.x2o["TAUX_east"]   .= datastream["TAUX"]
            OMDATA.x2o["TAUY_north"]  .= datastream["TAUY"]

            return_values = ( :RUN,  Δt, t_end_reached )
        else
            return_values = ( :END, 0.0, t_end_reached  )
        end

        return return_values
    end,

    master_after_model_run! = function(OMMODULE, OMDATA)
    end,

    master_finalize! = function(OMMODULE, OMDATA)
        writeLog("[Coupler] Finalize")
    end, 
)

runModel(
    ENGINE_EMOM, 
    coupler_funcs,
    config, 
)
