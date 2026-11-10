const SECONDS_IN_MINUTE = 60.0
const MINUTES_IN_HOUR = 60.0
const SECONDS_IN_HOUR = 3600.0
const MILLISECONDS_IN_HOUR = 3600000.0
const HOURS_IN_WEEK = 168.0
const GRAVITATIONAL_CONSTANT = 9.81
const WATER_DENSITY = 1000.0
const M3_TO_KM3 = 1e-9

"""
Heat equivalent of one megawatt-hour in `fuel_units` (3.6 for `u"GJ"`, 3.412 for `u"MMBtu"`),
derived with Unitful rather than typed as a literal.
"""
electrical_heat_equivalent(fuel_units::IS.Unitful.Units) =
    IS.Unitful.ustrip(IS.Unitful.uconvert(fuel_units, 1.0 * u"MW" * u"hr"))
