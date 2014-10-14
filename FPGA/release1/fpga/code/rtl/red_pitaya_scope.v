/**
 * $Id: red_pitaya_scope.v 965 2014-01-24 13:39:56Z matej.oblak $
 *
 * @brief Red Pitaya oscilloscope application, used for capturing ADC data
 *        into BRAMs, which can be later read by SW.
 *
 * @Author Matej Oblak
 *
 * (c) Red Pitaya  http://www.redpitaya.com
 *
 * This part of code is written in Verilog hardware description language (HDL).
 * Please visit http://en.wikipedia.org/wiki/Verilog
 * for more details on the language used herein.
 */



/**
 * GENERAL DESCRIPTION:
 *
 * This is simple data aquisition module, primerly used for scilloscope 
 * application. It consists from three main parts.
 *
 *
 *                /--------\      /-----------\            /-----\
 *   ADC CHA ---> | DFILT1 | ---> | AVG & DEC | ---------> | BUF | --->  SW
 *                \--------/      \-----------/     |      \-----/
 *                                                  ˇ         ^
 *                                              /------\      |
 *   ext trigger -----------------------------> | TRIG | -----+
 *                                              \------/      |
 *                                                  ^         ˇ
 *                /--------\      /-----------\     |      /-----\
 *   ADC CHB ---> | DFILT1 | ---> | AVG & DEC | ---------> | BUF | --->  SW
 *                \--------/      \-----------/            \-----/ 
 *
 *
 * Input data is optionaly averaged and decimated via average filter.
 *
 * Trigger section makes triggers from input ADC data or external digital 
 * signal. To make trigger from analog signal schmitt trigger is used, external
 * trigger goes first over debouncer, which is separate for pos. and neg. edge.
 *
 * Data capture buffer is realized with BRAM. Writing into ram is done with 
 * arm/trig logic. With adc_arm_do signal (SW) writing is enabled, this is active
 * until trigger arrives and adc_dly_cnt counts to zero. Value adc_wp_trig
 * serves as pointer which shows when trigger arrived. This is used to show
 * pre-trigger data.
 * 
 */



module red_pitaya_scope
(
   // ADC
   input      [ 14-1: 0] adc_a_i         ,  //!< ADC data CHA
   input      [ 14-1: 0] adc_b_i         ,  //!< ADC data CHB
   input                 adc_clk_i       ,  //!< ADC clock
   input                 adc_rstn_i      ,  //!< ADC reset - active low
   input                 trig_ext_i      ,  //!< external trigger
   input                 trig_asg_i      ,  //!< ASG trigger

   // System bus
   input                 sys_clk_i       ,  //!< bus clock
   input                 sys_rstn_i      ,  //!< bus reset - active low
   input      [ 32-1: 0] sys_addr_i      ,  //!< bus saddress
   input      [ 32-1: 0] sys_wdata_i     ,  //!< bus write data
   input      [  4-1: 0] sys_sel_i       ,  //!< bus write byte select
   input                 sys_wen_i       ,  //!< bus write enable
   input                 sys_ren_i       ,  //!< bus read enable
   output     [ 32-1: 0] sys_rdata_o     ,  //!< bus read data
   output                sys_err_o       ,  //!< bus error indicator
   output                sys_ack_o       ,  //!< bus acknowledge signal

`ifndef DDRDUMP_WITH_SYSBUS
    // DDR Dump parameter export
    output      [   32-1:0] ddr_a_base_o    ,   // DDR ChA buffer base address
    output      [   32-1:0] ddr_a_end_o     ,   // DDR ChA buffer end address + 1
    input       [   32-1:0] ddr_a_curr_i    ,   // DDR ChA current write address
    output      [   32-1:0] ddr_b_base_o    ,   // DDR ChB buffer base address
    output      [   32-1:0] ddr_b_end_o     ,   // DDR ChB buffer end address + 1
    input       [   32-1:0] ddr_b_curr_i    ,   // DDR ChB current write address
    output      [    4-1:0] ddr_control_o   ,   // DDR [0,1]: dump enable flag A/B, [2,3]: reload curr A/B
`endif
    // Remote ADC buffer readout
    input           adcbuf_clk_i        ,   // clock
    input           adcbuf_rstn_i       ,   // reset
    input  [ 2-1:0] adcbuf_select_i     ,   //
    output [ 4-1:0] adcbuf_ready_o      ,   // buffer ready [0]: ChA 0k-8k, [1]: ChA 8k-16k, [2]: ChB 0k-8k, [3]: ChB 8k-16k
    input  [12-1:0] adcbuf_raddr_i      ,   //
    output [64-1:0] adcbuf_rdata_o          //
);


wire [ 32-1: 0] addr         ;
wire [ 32-1: 0] wdata        ;
wire            wen          ;
wire            ren          ;
reg  [ 32-1: 0] rdata        ;
reg             err          ;
reg             ack          ;
reg             adc_arm_do   ;
reg             adc_rst_do   ;





//---------------------------------------------------------------------------------
//  Input filtering

wire [ 14-1: 0] adc_a_filt_in  ;
wire [ 14-1: 0] adc_a_filt_out ;
wire [ 14-1: 0] adc_b_filt_in  ;
wire [ 14-1: 0] adc_b_filt_out ;
reg  [ 18-1: 0] set_a_filt_aa  ;
reg  [ 25-1: 0] set_a_filt_bb  ;
reg  [ 25-1: 0] set_a_filt_kk  ;
reg  [ 25-1: 0] set_a_filt_pp  ;
reg  [ 18-1: 0] set_b_filt_aa  ;
reg  [ 25-1: 0] set_b_filt_bb  ;
reg  [ 25-1: 0] set_b_filt_kk  ;
reg  [ 25-1: 0] set_b_filt_pp  ;


assign adc_a_filt_in = adc_a_i ;
assign adc_b_filt_in = adc_b_i ;

red_pitaya_dfilt1 i_dfilt1_cha
(
   // ADC
  .adc_clk_i   ( adc_clk_i       ),  // ADC clock
  .adc_rstn_i  ( adc_rstn_i      ),  // ADC reset - active low
  .adc_dat_i   ( adc_a_filt_in   ),  // ADC data
  .adc_dat_o   ( adc_a_filt_out  ),  // ADC data

   // configuration
  .cfg_aa_i    ( set_a_filt_aa   ),  // config AA coefficient
  .cfg_bb_i    ( set_a_filt_bb   ),  // config BB coefficient
  .cfg_kk_i    ( set_a_filt_kk   ),  // config KK coefficient
  .cfg_pp_i    ( set_a_filt_pp   )   // config PP coefficient
);

red_pitaya_dfilt1 i_dfilt1_chb
(
   // ADC
  .adc_clk_i   ( adc_clk_i       ),  // ADC clock
  .adc_rstn_i  ( adc_rstn_i      ),  // ADC reset - active low
  .adc_dat_i   ( adc_b_filt_in   ),  // ADC data
  .adc_dat_o   ( adc_b_filt_out  ),  // ADC data

   // configuration
  .cfg_aa_i    ( set_b_filt_aa   ),  // config AA coefficient
  .cfg_bb_i    ( set_b_filt_bb   ),  // config BB coefficient
  .cfg_kk_i    ( set_b_filt_kk   ),  // config KK coefficient
  .cfg_pp_i    ( set_b_filt_pp   )   // config PP coefficient
);





//---------------------------------------------------------------------------------
//  Decimate input data

reg  [ 16-1: 0] adc_a_dat     ;
reg  [ 16-1: 0] adc_b_dat     ;
reg  [ 32-1: 0] adc_a_sum     ;
reg  [ 32-1: 0] adc_b_sum     ;
reg  [ 17-1: 0] set_dec       ;
reg  [ 17-1: 0] adc_dec_cnt   ;
reg             set_avg_en    ;
reg             adc_dv        ;

always @(posedge adc_clk_i) begin
   if (adc_rstn_i == 1'b0) begin
      adc_a_sum   <= 32'h0 ;
      adc_b_sum   <= 32'h0 ;
      adc_dec_cnt <= 17'h0 ;
      adc_dv      <=  1'b0 ;
   end
   else begin
      if ((adc_dec_cnt >= set_dec) || adc_arm_do) begin // start again or arm
         adc_dec_cnt <= 17'h1                   ;
         adc_a_sum   <= $signed(adc_a_filt_out) ;
         adc_b_sum   <= $signed(adc_b_filt_out) ;
      end
      else begin
         adc_dec_cnt <= adc_dec_cnt + 17'h1 ;
         adc_a_sum   <= $signed(adc_a_sum) + $signed(adc_a_filt_out) ;
         adc_b_sum   <= $signed(adc_b_sum) + $signed(adc_b_filt_out) ;
      end

      adc_dv <= (adc_dec_cnt >= set_dec) ;

      case (set_dec & {17{set_avg_en}})
         17'h0     : begin adc_a_dat <= adc_a_filt_out;            adc_b_dat <= adc_b_filt_out;        end
         17'h1     : begin adc_a_dat <= adc_a_sum[15+0 :  0];      adc_b_dat <= adc_b_sum[15+0 :  0];  end
         17'h8     : begin adc_a_dat <= adc_a_sum[15+3 :  3];      adc_b_dat <= adc_b_sum[15+3 :  3];  end
         17'h40    : begin adc_a_dat <= adc_a_sum[15+6 :  6];      adc_b_dat <= adc_b_sum[15+6 :  6];  end
         17'h400   : begin adc_a_dat <= adc_a_sum[15+10: 10];      adc_b_dat <= adc_b_sum[15+10: 10];  end
         17'h2000  : begin adc_a_dat <= adc_a_sum[15+13: 13];      adc_b_dat <= adc_b_sum[15+13: 13];  end
         17'h10000 : begin adc_a_dat <= adc_a_sum[15+16: 16];      adc_b_dat <= adc_b_sum[15+16: 16];  end
         default   : begin adc_a_dat <= adc_a_sum[15+0 :  0];      adc_b_dat <= adc_b_sum[15+0 :  0];  end
      endcase

   end
end





//---------------------------------------------------------------------------------
//  ADC buffer RAM

wire    [64-1:0]    buf_a_data_o;
wire    [64-1:0]    buf_b_data_o;

localparam RSZ = 14 ;  // RAM size 2^RSZ

reg   [ RSZ-1: 0] adc_wp        ;
reg               adc_we        ;
reg               adc_trig      ;

reg   [ RSZ-1: 0] adc_wp_trig   ;
reg   [ RSZ-1: 0] adc_wp_cur    ;
reg   [  32-1: 0] set_dly       ;
reg   [  32-1: 0] adc_dly_cnt   ;
reg               adc_dly_do    ;

adc_buffer adc_a_buffer (
    .clka   (adc_clk_i          ),
    .ena    (adc_dv             ),
    .wea    (adc_we             ),
    .addra  (adc_wp             ),
    .dina   (adc_a_dat          ),
    .clkb   (adcbuf_clk_i       ),
    .rstb   (!adcbuf_rstn_i     ),
    .enb    (adcbuf_select_i[0] ),
    .addrb  (adcbuf_raddr_i     ),
    .doutb  (buf_a_data_o       )
);

adc_buffer adc_b_buffer (
    .clka   (adc_clk_i          ),
    .ena    (adc_dv             ),
    .wea    (adc_we             ),
    .addra  (adc_wp             ),
    .dina   (adc_b_dat          ),
    .clkb   (adcbuf_clk_i       ),
    .rstb   (!adcbuf_rstn_i     ),
    .enb    (adcbuf_select_i[1] ),
    .addrb  (adcbuf_raddr_i     ),
    .doutb  (buf_b_data_o       )
);

assign adcbuf_rdata_o = {64{(adcbuf_select_i == 2'b01)}} & buf_a_data_o |
                        {64{(adcbuf_select_i == 2'b10)}} & buf_b_data_o;

(* ASYNC_REG="true" *)  reg     [2:0]   addr_sync;

always @(posedge adcbuf_clk_i) begin
    if (!adcbuf_rstn_i) begin
        addr_sync <= 3'b000;
    end else begin
        addr_sync <= {addr_sync[1:0],adc_wp[RSZ-1]};
    end
end

assign adcbuf_ready_o[0] = (addr_sync[1] ^ addr_sync[2]) &  addr_sync[1];
assign adcbuf_ready_o[1] = (addr_sync[1] ^ addr_sync[2]) & !addr_sync[1];
assign adcbuf_ready_o[2] = (addr_sync[1] ^ addr_sync[2]) &  addr_sync[1];
assign adcbuf_ready_o[3] = (addr_sync[1] ^ addr_sync[2]) & !addr_sync[1];


// Write
always @(posedge adc_clk_i) begin
    if (adc_rstn_i == 1'b0) begin
        adc_wp      <= {RSZ{1'b0}};
        adc_we      <=  1'b0      ;
        adc_wp_trig <= {RSZ{1'b0}};
        adc_wp_cur  <= {RSZ{1'b0}};
        adc_dly_cnt <= 32'h0      ;
        adc_dly_do  <=  1'b0      ;
    end else begin
        if (adc_arm_do)
            adc_we <= 1'b1 ;
        else if (((adc_dly_do || adc_trig) && (adc_dly_cnt == 32'h0)) || adc_rst_do) //delayed reached or reset
            adc_we <= 1'b0 ;


        if (adc_rst_do)
            adc_wp <= {RSZ{1'b0}};
        else if (adc_we && adc_dv)
            adc_wp <= adc_wp + 1'b1 ;

        if (adc_rst_do)
            adc_wp_trig <= {RSZ{1'b0}};
        else if (adc_trig && !adc_dly_do)
            adc_wp_trig <= adc_wp_cur ; // save write pointer at trigger arrival

        if (adc_rst_do)
            adc_wp_cur <= {RSZ{1'b0}};
        else if (adc_we && adc_dv)
            adc_wp_cur <= adc_wp ; // save current write pointer


        if (adc_trig)
            adc_dly_do  <= 1'b1 ;
        else if ((adc_dly_do && (adc_dly_cnt == 32'b0)) || adc_rst_do || adc_arm_do) //delayed reached or reset
            adc_dly_do  <= 1'b0 ;

        if (adc_dly_do && adc_we && adc_dv)
            adc_dly_cnt <= adc_dly_cnt + {32{1'b1}} ; // -1
        else if (!adc_dly_do)
            adc_dly_cnt <= set_dly ;

    end
end





//---------------------------------------------------------------------------------
//
//  Trigger source selector

reg               adc_trig_ap      ;
reg               adc_trig_an      ;
reg               adc_trig_bp      ;
reg               adc_trig_bn      ;
reg               adc_trig_sw      ;
reg   [   4-1: 0] set_trig_src     ;
wire              ext_trig_p       ;
wire              ext_trig_n       ;
wire              asg_trig_p       ;
wire              asg_trig_n       ;


always @(posedge adc_clk_i) begin
   if (adc_rstn_i == 1'b0) begin
      adc_arm_do    <= 1'b0 ;
      adc_rst_do    <= 1'b0 ;
      adc_trig_sw   <= 1'b0 ;
      set_trig_src  <= 4'h0 ;
      adc_trig      <= 1'b0 ;
   end
   else begin
      adc_arm_do  <= wen && (addr[19:0]==20'h0) && wdata[0] ; // SW ARM
      adc_rst_do  <= wen && (addr[19:0]==20'h0) && wdata[1] ;
      adc_trig_sw <= wen && (addr[19:0]==20'h4) ; // SW trigger

      if (wen && (addr[19:0]==20'h4))
         set_trig_src <= wdata[3:0] ;
      else if (((adc_dly_do || adc_trig) && (adc_dly_cnt == 32'h0)) || adc_rst_do) //delayed reached or reset
         set_trig_src <= 4'h0 ;

      case (set_trig_src)
          4'd1 : adc_trig <= adc_trig_sw   ; // manual
          4'd2 : adc_trig <= adc_trig_ap   ; // A ch rising edge
          4'd3 : adc_trig <= adc_trig_an   ; // A ch falling edge
          4'd4 : adc_trig <= adc_trig_bp   ; // B ch rising edge
          4'd5 : adc_trig <= adc_trig_bn   ; // B ch falling edge
          4'd6 : adc_trig <= ext_trig_p    ; // external - rising edge
          4'd7 : adc_trig <= ext_trig_n    ; // external - falling edge
          4'd8 : adc_trig <= asg_trig_p    ; // ASG - rising edge
          4'd9 : adc_trig <= asg_trig_n    ; // ASG - falling edge
       default : adc_trig <= 1'b0          ;
      endcase
   end
end





//---------------------------------------------------------------------------------
//
//  Trigger created from input signal

reg  [  2-1: 0] adc_scht_ap  ;
reg  [  2-1: 0] adc_scht_an  ;
reg  [  2-1: 0] adc_scht_bp  ;
reg  [  2-1: 0] adc_scht_bn  ;
reg  [ 16-1: 0] set_a_tresh  ;
reg  [ 16-1: 0] set_a_treshp ;
reg  [ 16-1: 0] set_a_treshm ;
reg  [ 16-1: 0] set_b_tresh  ;
reg  [ 16-1: 0] set_b_treshp ;
reg  [ 16-1: 0] set_b_treshm ;
reg  [ 16-1: 0] set_a_hyst   ;
reg  [ 16-1: 0] set_b_hyst   ;

always @(posedge adc_clk_i) begin
   if (adc_rstn_i == 1'b0) begin
      adc_scht_ap  <=  2'h0 ;
      adc_scht_an  <=  2'h0 ;
      adc_scht_bp  <=  2'h0 ;
      adc_scht_bn  <=  2'h0 ;
      adc_trig_ap  <=  1'b0 ;
      adc_trig_an  <=  1'b0 ;
      adc_trig_bp  <=  1'b0 ;
      adc_trig_bn  <=  1'b0 ;
   end
   else begin
      set_a_treshp <= set_a_tresh + set_a_hyst ; // calculate positive
      set_a_treshm <= set_a_tresh - set_a_hyst ; // and negative treshold
      set_b_treshp <= set_b_tresh + set_b_hyst ;
      set_b_treshm <= set_b_tresh - set_b_hyst ;

      if (adc_dv) begin
              if ($signed(adc_a_dat) >= $signed(set_a_tresh ))      adc_scht_ap[0] <= 1'b1 ;  // treshold reached
         else if ($signed(adc_a_dat) <  $signed(set_a_treshm))      adc_scht_ap[0] <= 1'b0 ;  // wait until it goes under hysteresis
              if ($signed(adc_a_dat) <= $signed(set_a_tresh ))      adc_scht_an[0] <= 1'b1 ;  // treshold reached
         else if ($signed(adc_a_dat) >  $signed(set_a_treshp))      adc_scht_an[0] <= 1'b0 ;  // wait until it goes over hysteresis

              if ($signed(adc_b_dat) >= $signed(set_b_tresh ))      adc_scht_bp[0] <= 1'b1 ;
         else if ($signed(adc_b_dat) <  $signed(set_b_treshm))      adc_scht_bp[0] <= 1'b0 ;
              if ($signed(adc_b_dat) <= $signed(set_b_tresh ))      adc_scht_bn[0] <= 1'b1 ;
         else if ($signed(adc_b_dat) >  $signed(set_b_treshp))      adc_scht_bn[0] <= 1'b0 ;
      end

      adc_scht_ap[1] <= adc_scht_ap[0] ;
      adc_scht_an[1] <= adc_scht_an[0] ;
      adc_scht_bp[1] <= adc_scht_bp[0] ;
      adc_scht_bn[1] <= adc_scht_bn[0] ;

      adc_trig_ap <= adc_scht_ap[0] && !adc_scht_ap[1] ; // make 1 cyc pulse 
      adc_trig_an <= adc_scht_an[0] && !adc_scht_an[1] ;
      adc_trig_bp <= adc_scht_bp[0] && !adc_scht_bp[1] ;
      adc_trig_bn <= adc_scht_bn[0] && !adc_scht_bn[1] ;
   end
end





//---------------------------------------------------------------------------------
//
//  External trigger

reg  [  3-1: 0] ext_trig_in    ;
reg  [  2-1: 0] ext_trig_dp    ;
reg  [  2-1: 0] ext_trig_dn    ;
reg  [ 20-1: 0] ext_trig_debp  ;
reg  [ 20-1: 0] ext_trig_debn  ;
reg  [  3-1: 0] asg_trig_in    ;
reg  [  2-1: 0] asg_trig_dp    ;
reg  [  2-1: 0] asg_trig_dn    ;
reg  [ 20-1: 0] asg_trig_debp  ;
reg  [ 20-1: 0] asg_trig_debn  ;


always @(posedge adc_clk_i) begin
   if (adc_rstn_i == 1'b0) begin
      ext_trig_in   <=  3'h0 ;
      ext_trig_dp   <=  2'h0 ;
      ext_trig_dn   <=  2'h0 ;
      ext_trig_debp <= 20'h0 ;
      ext_trig_debn <= 20'h0 ;
      asg_trig_in   <=  3'h0 ;
      asg_trig_dp   <=  2'h0 ;
      asg_trig_dn   <=  2'h0 ;
      asg_trig_debp <= 20'h0 ;
      asg_trig_debn <= 20'h0 ;
   end
   else begin
      //----------- External trigger
      // synchronize FFs
      ext_trig_in <= {ext_trig_in[1:0],trig_ext_i} ;

      // look for input changes
      if ((ext_trig_debp == 20'h0) && (ext_trig_in[1] && !ext_trig_in[2]))
         ext_trig_debp <= 20'd62500 ; // ~0.5ms
      else if (ext_trig_debp != 20'h0)
         ext_trig_debp <= ext_trig_debp - 20'd1 ;

      if ((ext_trig_debn == 20'h0) && (!ext_trig_in[1] && ext_trig_in[2]))
         ext_trig_debn <= 20'd62500 ; // ~0.5ms
      else if (ext_trig_debn != 20'h0)
         ext_trig_debn <= ext_trig_debn - 20'd1 ;

      // update output values
      ext_trig_dp[1] <= ext_trig_dp[0] ;
      if (ext_trig_debp == 20'h0)
         ext_trig_dp[0] <= ext_trig_in[1] ;

      ext_trig_dn[1] <= ext_trig_dn[0] ;
      if (ext_trig_debn == 20'h0)
         ext_trig_dn[0] <= ext_trig_in[1] ;




      //----------- ASG trigger
      // synchronize FFs
      asg_trig_in <= {asg_trig_in[1:0],trig_asg_i} ;

      // look for input changes
      if ((asg_trig_debp == 20'h0) && (asg_trig_in[1] && !asg_trig_in[2]))
         asg_trig_debp <= 20'd62500 ; // ~0.5ms
      else if (asg_trig_debp != 20'h0)
         asg_trig_debp <= asg_trig_debp - 20'd1 ;

      if ((asg_trig_debn == 20'h0) && (!asg_trig_in[1] && asg_trig_in[2]))
         asg_trig_debn <= 20'd62500 ; // ~0.5ms
      else if (asg_trig_debn != 20'h0)
         asg_trig_debn <= asg_trig_debn - 20'd1 ;

      // update output values
      asg_trig_dp[1] <= asg_trig_dp[0] ;
      if (asg_trig_debp == 20'h0)
         asg_trig_dp[0] <= asg_trig_in[1] ;

      asg_trig_dn[1] <= asg_trig_dn[0] ;
      if (asg_trig_debn == 20'h0)
         asg_trig_dn[0] <= asg_trig_in[1] ;
   end
end


assign ext_trig_p = (ext_trig_dp == 2'b01) ;
assign ext_trig_n = (ext_trig_dn == 2'b10) ;
assign asg_trig_p = (asg_trig_dp == 2'b01) ;
assign asg_trig_n = (asg_trig_dn == 2'b10) ;





//---------------------------------------------------------------------------------
//
//  System bus connection

`ifndef DDRDUMP_WITH_SYSBUS
reg  [  32-1:0] ddr_a_base;     // DDR ChA buffer base address
reg  [  32-1:0] ddr_a_end;      // DDR ChA buffer end address + 1
reg  [  32-1:0] ddr_b_base;     // DDR ChB buffer base address
reg  [  32-1:0] ddr_b_end;      // DDR ChB buffer end address + 1
reg  [   4-1:0] ddr_control;    // DDR [0,1]: dump enable flag A/B, [2,3]: reload curr A/B

assign ddr_a_base_o  = ddr_a_base;
assign ddr_a_end_o   = ddr_a_end;
assign ddr_b_base_o  = ddr_b_base;
assign ddr_b_end_o   = ddr_b_end;
assign ddr_control_o = ddr_control;
`endif

always @(posedge adc_clk_i) begin
   if (adc_rstn_i == 1'b0) begin
      set_a_tresh   <=  16'd20000  ;
      set_b_tresh   <= -16'd20000  ;
      set_dly       <=  32'd0      ;
      set_dec       <=  17'd1      ;
      set_a_hyst    <=  16'd80     ;
      set_b_hyst    <=  16'd80     ;
      set_avg_en    <=   1'b1      ;
      set_a_filt_aa <=  18'h0      ;
      set_a_filt_bb <=  25'h0      ;
      set_a_filt_kk <=  25'hFFFFFF ;
      set_a_filt_pp <=  25'h0      ;
      set_b_filt_aa <=  18'h0      ;
      set_b_filt_bb <=  25'h0      ;
      set_b_filt_kk <=  25'hFFFFFF ;
      set_b_filt_pp <=  25'h0      ;
`ifndef DDRDUMP_WITH_SYSBUS
        ddr_a_base  <= 32'h00000000;
        ddr_a_end   <= 32'h00000000;
        ddr_b_base  <= 32'h00000000;
        ddr_b_end   <= 32'h00000000;
        ddr_control <= 4'b0000;
`endif
   end
   else begin
      if (wen) begin
         if (addr[19:0]==20'h8)    set_a_tresh <= wdata[16-1:0] ;
         if (addr[19:0]==20'hC)    set_b_tresh <= wdata[16-1:0] ;
         if (addr[19:0]==20'h10)   set_dly     <= wdata[32-1:0] ;
         if (addr[19:0]==20'h14)   set_dec     <= wdata[17-1:0] ;
         if (addr[19:0]==20'h20)   set_a_hyst  <= wdata[16-1:0] ;
         if (addr[19:0]==20'h24)   set_b_hyst  <= wdata[16-1:0] ;
         if (addr[19:0]==20'h28)   set_avg_en  <= wdata[     0] ;

         if (addr[19:0]==20'h30)   set_a_filt_aa <= wdata[18-1:0] ;
         if (addr[19:0]==20'h34)   set_a_filt_bb <= wdata[25-1:0] ;
         if (addr[19:0]==20'h38)   set_a_filt_kk <= wdata[25-1:0] ;
         if (addr[19:0]==20'h3C)   set_a_filt_pp <= wdata[25-1:0] ;
         if (addr[19:0]==20'h40)   set_b_filt_aa <= wdata[18-1:0] ;
         if (addr[19:0]==20'h44)   set_b_filt_bb <= wdata[25-1:0] ;
         if (addr[19:0]==20'h48)   set_b_filt_kk <= wdata[25-1:0] ;
         if (addr[19:0]==20'h4C)   set_b_filt_pp <= wdata[25-1:0] ;

`ifndef DDRDUMP_WITH_SYSBUS
            if (addr[19:0]==20'h60) ddr_a_base  <= wdata;
            if (addr[19:0]==20'h64) ddr_a_end   <= wdata;
            if (addr[19:0]==20'h68) ddr_b_base  <= wdata;
            if (addr[19:0]==20'h6c) ddr_b_end   <= wdata;
            if (addr[19:0]==20'h70) ddr_control <= wdata[4-1:0];
`endif
      end
   end
end





always @(*) begin
   err <= 1'b0 ;

   case (addr[19:0])
     20'h00004 : begin ack <= 1'b1;          rdata <= {{32- 4{1'b0}}, set_trig_src}       ; end 

     20'h00008 : begin ack <= 1'b1;          rdata <= {{32-16{1'b0}}, set_a_tresh}        ; end
     20'h0000C : begin ack <= 1'b1;          rdata <= {{32-16{1'b0}}, set_b_tresh}        ; end
     20'h00010 : begin ack <= 1'b1;          rdata <= {               set_dly}            ; end
     20'h00014 : begin ack <= 1'b1;          rdata <= {{32-17{1'b0}}, set_dec}            ; end

     20'h00018 : begin ack <= 1'b1;          rdata <= {{32-RSZ{1'b0}}, adc_wp_cur}        ; end
     20'h0001C : begin ack <= 1'b1;          rdata <= {{32-RSZ{1'b0}}, adc_wp_trig}       ; end

     20'h00020 : begin ack <= 1'b1;          rdata <= {{32-16{1'b0}}, set_a_hyst}         ; end
     20'h00024 : begin ack <= 1'b1;          rdata <= {{32-16{1'b0}}, set_b_hyst}         ; end

     20'h00028 : begin ack <= 1'b1;          rdata <= {{32- 1{1'b0}}, set_avg_en}         ; end

     20'h00030 : begin ack <= 1'b1;          rdata <= {{32-18{1'b0}}, set_a_filt_aa}      ; end
     20'h00034 : begin ack <= 1'b1;          rdata <= {{32-25{1'b0}}, set_a_filt_bb}      ; end
     20'h00038 : begin ack <= 1'b1;          rdata <= {{32-25{1'b0}}, set_a_filt_kk}      ; end
     20'h0003C : begin ack <= 1'b1;          rdata <= {{32-25{1'b0}}, set_a_filt_pp}      ; end
     20'h00040 : begin ack <= 1'b1;          rdata <= {{32-18{1'b0}}, set_b_filt_aa}      ; end
     20'h00044 : begin ack <= 1'b1;          rdata <= {{32-25{1'b0}}, set_b_filt_bb}      ; end
     20'h00048 : begin ack <= 1'b1;          rdata <= {{32-25{1'b0}}, set_b_filt_kk}      ; end
     20'h0004C : begin ack <= 1'b1;          rdata <= {{32-25{1'b0}}, set_b_filt_pp}      ; end

`ifndef DDRDUMP_WITH_SYSBUS
    20'h00060 : begin   ack <= 1'b1;    rdata <= ddr_a_base;    end
    20'h00064 : begin   ack <= 1'b1;    rdata <= ddr_a_end;     end
    20'h00068 : begin   ack <= 1'b1;    rdata <= ddr_b_base;    end
    20'h0006c : begin   ack <= 1'b1;    rdata <= ddr_b_end;     end
    20'h00074 : begin   ack <= 1'b1;    rdata <= ddr_a_curr_i;  end
    20'h00078 : begin   ack <= 1'b1;    rdata <= ddr_b_curr_i;  end
`endif

       default : begin ack <= 1'b1;          rdata <=  32'h0                              ; end
   endcase
end





// bridge between ADC and sys clock
bus_clk_bridge i_bridge_scope
(
   .sys_clk_i     (  sys_clk_i      ),
   .sys_rstn_i    (  sys_rstn_i     ),
   .sys_addr_i    (  sys_addr_i     ),
   .sys_wdata_i   (  sys_wdata_i    ),
   .sys_sel_i     (  sys_sel_i      ),
   .sys_wen_i     (  sys_wen_i      ),
   .sys_ren_i     (  sys_ren_i      ),
   .sys_rdata_o   (  sys_rdata_o    ),
   .sys_err_o     (  sys_err_o      ),
   .sys_ack_o     (  sys_ack_o      ),

   .clk_i         (  adc_clk_i      ),
   .rstn_i        (  adc_rstn_i     ),
   .addr_o        (  addr           ),
   .wdata_o       (  wdata          ),
   .wen_o         (  wen            ),
   .ren_o         (  ren            ),
   .rdata_i       (  rdata          ),
   .err_i         (  err            ),
   .ack_i         (  ack            )
);





endmodule
