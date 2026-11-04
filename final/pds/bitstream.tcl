cd [file dirname [file normalize [info script]]]
set_arch -family Logos2 -device PG2L200H -speedgrade -6 -package FBB676
gen_bit_stream -force_to_run -input_db_file {place_route/test_ddr_pnr.adf} -scbv {High Voltage}
