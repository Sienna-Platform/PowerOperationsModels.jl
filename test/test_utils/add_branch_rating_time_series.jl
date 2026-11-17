function add_branch_rating_time_series_to_system!(
    sys::System,
    branches_with_rating_ts::Vector{String},
    n_steps::Int,
    rating_factors::Vector{Float64};
    initial_date::String = "2020-01-01",
    ts_name::String = "branch_rating",
    base_rating = PNM.get_equivalent_rating,
)
    # Add a time-varying branch rating (e.g. dynamic line ratings) to the system, in MVA:
    # `rating_factors` times the branch's `base_rating` (system base).
    for branch_name in branches_with_rating_ts
        branch = get_component(ACTransmission, sys, branch_name)
        rating_mva = base_rating(branch) * get_base_power(sys)
        rating_data = SortedDict{Dates.DateTime, TimeSeries.TimeArray}()
        data_ts = collect(
            DateTime("$initial_date 0:00:00", "y-m-d H:M:S"):Hour(1):(
                DateTime("$initial_date 23:00:00", "y-m-d H:M:S")
            ),
        )
        for t in 1:n_steps
            ini_time = data_ts[1] + Day(t - 1)
            rating_data[ini_time] =
                TimeArray(
                    data_ts + Day(t - 1),
                    rating_factors .* rating_mva,
                )
        end

        PowerSystems.add_time_series!(
            sys,
            branch,
            PowerSystems.Deterministic(
                ts_name,
                rating_data;
                units = "MVA",
                quantity_kind = "apparent_power",
            ),
        )
    end
end
