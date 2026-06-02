---
name: grid-converter
description: Convert coordinates between MGRS, decimal latitude/longitude, and UTM formats.
---

# Grid Converter

Convert between MGRS, decimal latitude/longitude, and UTM.

## Instructions

- Use only the user's input.
- Return JSON only.
- Do not add markdown, prose, or commentary.
- If the request is ambiguous, return a JSON object with an `error` field.

## Examples

- "Convert 33UXP0450007500 to lat long"
- "What is 38.8977 -77.0365 in MGRS?"
- "Convert lat 34.05 lon -118.24 to UTM"
- "Convert UTM zone 18 easting 323394 northing 4307396 to MGRS"
- "What grid is the Pentagon at?"

## JSON Shape

Return one object with:

- `conversion`: `mgrs_to_ll`, `ll_to_mgrs`, `ll_to_utm`, `utm_to_ll`, `mgrs_to_utm`, or `utm_to_mgrs`
- `mgrs` for MGRS inputs
- `lat` and `lon` for latitude/longitude inputs
- `zoneNumber`, `zoneLetter`, `easting`, and `northing` for UTM inputs

Return only the JSON payload needed by the tool caller.
