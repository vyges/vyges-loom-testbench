// Two clock domains. a_q is launched by a flop on clk_a and captured directly by
// a flop on clk_b with no synchronizer -> an unsynchronized clock-domain crossing.
module cdc_demo (clk_a, clk_b, d_in, q_out);
  input clk_a, clk_b, d_in;
  output q_out;
  wire a_q;
  DFF ff_a (.CK(clk_a), .D(d_in), .Q(a_q));
  DFF ff_b (.CK(clk_b), .D(a_q),  .Q(q_out));
endmodule
