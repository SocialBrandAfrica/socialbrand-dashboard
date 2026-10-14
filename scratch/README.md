# scratch/

One-off simulation and read-back scripts. They are NOT migrations and are not part of the source of record in `sql/`.
Each writes only `cc_scratch_*` tables (service_role only) and is dropped after PM reads the result.
Rule (PM 14-10-2026): no tests or scratch builds on the live database between 07:00 and 20:00 SAST.

| File | What it did | Ticket |
|---|---|---|
| `sim_item2_fit_floors.sql` | The recipe with the fit floor taken off the non-protected lines, against the live recipe. | BLOOM-035 item 2 |
| `sim_item2_route_grain.sql` | The route-grain, cycle-aware fit simulated on 28 desks before the apply. | BLOOM-035 item 2 |
| `readback_item2_own_need.sql` | The live recipe against each desk's own need, after the apply. | BLOOM-035 item 2 |
