////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Developer:      Alin Parcalab - alin.parcalab@allengra.eu                  //
//                                                                            //
// Design Name:    Load Store Unit                                            //
// Project Name:   ARCINO                                                     //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Load Store Unit, used to eliminate multiple access during  //
//                 processor stalls, and to align bytes and halfwords         //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

/**
 * Load Store Unit
 *
 * Load Store Unit, used to eliminate multiple access during processor stalls,
 * and to align bytes and halfwords.
 */
module arcino_load_store_unit (
    input  logic         clk_i,
    input  logic         rst_ni,

    // output to data memory
    output logic         data_req_o,
    input  logic         data_gnt_i,
    input  logic         data_rvalid_i,
    input  logic         data_err_i,

    output logic [31:0]  data_addr_o,
    output logic         data_we_o,
    output logic [3:0]   data_be_o,
    output logic [31:0]  data_wdata_o,
    input  logic [31:0]  data_rdata_i,

    // signals from ex stage
    input  logic         data_we_ex_i,         // write enable                      -> from ex stage
    input  logic [1:0]   data_type_ex_i,       // Data type word, halfword, byte    -> from ex stage
    input  logic [31:0]  data_wdata_ex_i,      // data to write to memory           -> from ex stage
    input  logic [1:0]   data_reg_offset_ex_i, // offset inside register for stores -> from ex stage
    input  logic         data_sign_ext_ex_i,   // sign extension                    -> from ex stage

    output logic [31:0]  data_rdata_ex_o,      // requested data                    -> to ex stage
    input  logic         data_req_ex_i,        // data request                      -> from ex stage

    input  logic [31:0]  adder_result_ex_i,

    output logic         data_misaligned_o,    // misaligned access was detected    -> to controller
    output logic [31:0]  misaligned_addr_o,

    // exception signals
    output logic         load_err_o,
    output logic         store_err_o,

    // stall signal
    output logic         lsu_update_addr_o, // LSU ready for new data in EX stage
    output logic         data_valid_o,

    output logic         busy_o
);

  logic [31:0]  data_addr_int;

  // registers for data_rdata alignment and sign extension
  logic [1:0]   data_type_q;
  logic [1:0]   rdata_offset_q;
  logic         data_sign_ext_q;
  logic         data_we_q;

  logic [1:0]   wdata_offset;   // mux control for data to be written to memory

  logic [3:0]   data_be;
  logic [31:0]  data_wdata;

  logic         misaligned_st;   // high if we are currently performing the second part
                                 // of a misaligned store
  logic         data_misaligned, data_misaligned_q;
  logic         increase_address;

  typedef enum logic [2:0]  {
    IDLE, WAIT_GNT_MIS, WAIT_RVALID_MIS, WAIT_GNT, WAIT_RVALID
  } ls_fsm_e;

  ls_fsm_e CS, NS;

  logic [31:0]  rdata_q;

  ///////////////////
  // BE generation //
  ///////////////////
  always_comb begin
    case (data_type_ex_i) // Data type 00 Word, 01 Half word, 11,10 byte
      2'b00: begin // Writing a word
        if (!misaligned_st) begin // non-misaligned case
          unique case (data_addr_int[1:0])
            2'b00: data_be = 4'b1111;
            2'b01: data_be = 4'b1110;
            2'b10: data_be = 4'b1100;
            2'b11: data_be = 4'b1000;
          endcase // case (data_addr_int[1:0])
        end else begin // misaligned case
          unique case (data_addr_int[1:0])
            2'b00: data_be = 4'b0000; // this is not used, but included for completeness
            2'b01: data_be = 4'b0001;
            2'b10: data_be = 4'b0011;
            2'b11: data_be = 4'b0111;
          endcase // case (data_addr_int[1:0])
        end
      end

      2'b01: begin // Writing a half word
        if (!misaligned_st) begin // non-misaligned case
          unique case (data_addr_int[1:0])
            2'b00: data_be = 4'b0011;
            2'b01: data_be = 4'b0110;
            2'b10: data_be = 4'b1100;
            2'b11: data_be = 4'b1000;
          endcase // case (data_addr_int[1:0])
        end else begin // misaligned case
          data_be = 4'b0001;
        end
      end

      2'b10,
      2'b11: begin // Writing a byte
        unique case (data_addr_int[1:0])
          2'b00: data_be = 4'b0001;
          2'b01: data_be = 4'b0010;
          2'b10: data_be = 4'b0100;
          2'b11: data_be = 4'b1000;
        endcase // case (data_addr_int[1:0])
      end
    endcase // case (data_type_ex_i)
  end

  // prepare data to be written to the memory
  // we handle misaligned accesses, half word and byte accesses and
  // register offsets here
  assign wdata_offset = data_addr_int[1:0] - data_reg_offset_ex_i[1:0];
  always_comb begin
    unique case (wdata_offset)
      2'b00: data_wdata = data_wdata_ex_i[31:0];
      2'b01: data_wdata = {data_wdata_ex_i[23:0], data_wdata_ex_i[31:24]};
      2'b10: data_wdata = {data_wdata_ex_i[15:0], data_wdata_ex_i[31:16]};
      2'b11: data_wdata = {data_wdata_ex_i[ 7:0], data_wdata_ex_i[31: 8]};
    endcase // case (wdata_offset)
  end


  // FF for rdata alignment and sign-extension
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      data_type_q     <= 2'h0;
      rdata_offset_q  <= 2'h0;
      data_sign_ext_q <= 1'b0;
      data_we_q       <= 1'b0;
    end else if (data_gnt_i) begin
      // request was granted, we wait for rvalid and can continue to WB
      data_type_q     <= data_type_ex_i;
      rdata_offset_q  <= data_addr_int[1:0];
      data_sign_ext_q <= data_sign_ext_ex_i;
      data_we_q       <= data_we_ex_i;
    end
  end

  ////////////////////
  // Sign extension //
  ////////////////////

  logic [31:0] data_rdata_ext;

  logic [31:0] rdata_w_ext; // sign extension for words, actually only misaligned assembly
  logic [31:0] rdata_h_ext; // sign extension for half words
  logic [31:0] rdata_b_ext; // sign extension for bytes

  // take care of misaligned words
  always_comb begin
    case (rdata_offset_q)
      2'b00: rdata_w_ext = data_rdata_i[31:0];
      2'b01: rdata_w_ext = {data_rdata_i[ 7:0], rdata_q[31:8]};
      2'b10: rdata_w_ext = {data_rdata_i[15:0], rdata_q[31:16]};
      2'b11: rdata_w_ext = {data_rdata_i[23:0], rdata_q[31:24]};
    endcase
  end

  // sign extension for half words
  always_comb begin
    case (rdata_offset_q)
      2'b00: begin
        if (!data_sign_ext_q) begin
          rdata_h_ext = {16'h0000, data_rdata_i[15:0]};
        end else begin
          rdata_h_ext = {{16{data_rdata_i[15]}}, data_rdata_i[15:0]};
        end
      end

      2'b01: begin
        if (!data_sign_ext_q) begin
          rdata_h_ext = {16'h0000, data_rdata_i[23:8]};
        end else begin
          rdata_h_ext = {{16{data_rdata_i[23]}}, data_rdata_i[23:8]};
        end
      end

      2'b10: begin
        if (!data_sign_ext_q) begin
          rdata_h_ext = {16'h0000, data_rdata_i[31:16]};
        end else begin
          rdata_h_ext = {{16{data_rdata_i[31]}}, data_rdata_i[31:16]};
        end
      end

      2'b11: begin
        if (!data_sign_ext_q) begin
          rdata_h_ext = {16'h0000, data_rdata_i[7:0], rdata_q[31:24]};
        end else begin
          rdata_h_ext = {{16{data_rdata_i[7]}}, data_rdata_i[7:0], rdata_q[31:24]};
        end
      end
    endcase // case (rdata_offset_q)
  end

  // sign extension for bytes
  always_comb begin
    case (rdata_offset_q)
      2'b00: begin
        if (!data_sign_ext_q) begin
          rdata_b_ext = {24'h00_0000, data_rdata_i[7:0]};
        end else begin
          rdata_b_ext = {{24{data_rdata_i[7]}}, data_rdata_i[7:0]};
        end
      end

      2'b01: begin
        if (!data_sign_ext_q) begin
          rdata_b_ext = {24'h00_0000, data_rdata_i[15:8]};
        end else begin
          rdata_b_ext = {{24{data_rdata_i[15]}}, data_rdata_i[15:8]};
        end
      end

      2'b10: begin
        if (!data_sign_ext_q) begin
          rdata_b_ext = {24'h00_0000, data_rdata_i[23:16]};
        end else begin
          rdata_b_ext = {{24{data_rdata_i[23]}}, data_rdata_i[23:16]};
        end
      end

      2'b11: begin
        if (!data_sign_ext_q) begin
          rdata_b_ext = {24'h00_0000, data_rdata_i[31:24]};
        end else begin
          rdata_b_ext = {{24{data_rdata_i[31]}}, data_rdata_i[31:24]};
        end
      end
    endcase // case (rdata_offset_q)
  end

  // select word, half word or byte sign extended version
  always_comb begin
    case (data_type_q)
      2'b00:       data_rdata_ext = rdata_w_ext;
      2'b01:       data_rdata_ext = rdata_h_ext;
      2'b10,2'b11: data_rdata_ext = rdata_b_ext;
    endcase //~case(rdata_type_q)
  end



  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      CS            <= IDLE;
      rdata_q       <= '0;
      data_misaligned_q <= '0;
      misaligned_addr_o <= 32'b0;
    end else begin
      CS            <= NS;
      if (lsu_update_addr_o) begin
        data_misaligned_q <= data_misaligned;
        if (increase_address) begin
          misaligned_addr_o <= data_addr_int;
        end
      end
      if (data_rvalid_i && !data_we_q) begin
        // if we have detected a misaligned access, and we are
        // currently doing the first part of this access, then
        // store the data coming from memory in rdata_q.
        // In all other cases, rdata_q gets the value that we are
        // writing to the register file

        if (data_misaligned_q || data_misaligned) begin
          rdata_q  <= data_rdata_i;
        end else begin
          rdata_q  <= data_rdata_ext;
        end
      end
    end
  end

  // output to register file
  assign data_rdata_ex_o = data_rvalid_i ? data_rdata_ext : rdata_q;

  // output to data interface
  assign data_addr_o   = data_addr_int;
  assign data_wdata_o  = data_wdata;
  assign data_we_o     = data_we_ex_i;
  assign data_be_o     = data_be;

  assign misaligned_st = data_misaligned_q;

  assign load_err_o    = 1'b0;
  assign store_err_o   = 1'b0;

  // FSM
  always_comb begin
    NS             = CS;

    data_req_o     = 1'b0;

    lsu_update_addr_o   = 1'b0;

    data_valid_o     = 1'b0;
    increase_address = 1'b0;
    data_misaligned_o = 1'b0;

    case(CS)
      // starts from not active and stays in IDLE until request was granted
      IDLE: begin
        if (data_req_ex_i) begin
          data_req_o     = data_req_ex_i;
          if (data_gnt_i) begin
            lsu_update_addr_o   = 1'b1;
            increase_address = data_misaligned;
            NS = data_misaligned ? WAIT_RVALID_MIS : WAIT_RVALID;
          end else begin
            NS = data_misaligned ? WAIT_GNT_MIS    : WAIT_GNT;
          end
        end
      end // IDLE

      WAIT_GNT_MIS: begin
        data_req_o = 1'b1;
        if (data_gnt_i) begin
          lsu_update_addr_o = 1'b1;
          increase_address  = data_misaligned;
          NS = WAIT_RVALID_MIS;
        end
      end // WAIT_GNT_MIS

      // wait for rvalid in WB stage and send a new request if there is any
      WAIT_RVALID_MIS: begin
        //increase_address goes down, we already have the proper address
        increase_address  = 1'b0;
        //tell the controller to update the address
        data_misaligned_o = 1'b1;
        data_req_o        = 1'b0;
        lsu_update_addr_o = data_gnt_i;

        if (data_rvalid_i) begin
          //if first part rvalid is received
          data_req_o        = 1'b1;
          if (data_gnt_i) begin
            //second grant is received
            NS             = WAIT_RVALID;
            //in this stage we already received the first valid but no the second one
            //it differes from WAIT_RVALID_MIS because we do not send other requests
          end else begin
            //second grant is NOT received, but first rvalid yes
            //lsu_update_addr_o is 0 so data_misaligned_q stays high in WAIT_GNT
            //increase address stays the same as well
            NS              = WAIT_GNT; //  [1]
          end
        end else begin
          //if first part rvalid is NOT received
          //the second grand is not received either by protocol.
          //stay here
          NS                 = WAIT_RVALID_MIS;
        end
      end

      WAIT_GNT: begin
        data_misaligned_o = data_misaligned_q;
        //useful in case [1]
        data_req_o        = 1'b1;
        if (data_gnt_i) begin
          lsu_update_addr_o = 1'b1;
          NS = WAIT_RVALID;
        end
      end //~ WAIT_GNT

      WAIT_RVALID: begin
        data_req_o        = 1'b0;

        if (data_rvalid_i) begin
          data_valid_o = 1'b1;
          NS           = IDLE;
        end else begin
          NS           = WAIT_RVALID;
        end
      end //~ WAIT_RVALID


      default: begin
        NS = IDLE;
      end
    endcase
  end

  // check for misaligned accesses that need a second memory access
  // If one is detected, this is signaled with data_misaligned_o to
  // the controller which selectively stalls the pipeline
  always_comb begin
    data_misaligned = 1'b0;

    if (data_req_ex_i && !data_misaligned_q) begin
      case (data_type_ex_i)
        2'b00: begin // word
          if (data_addr_int[1:0] != 2'b00) begin
            data_misaligned = 1'b1;
          end
        end
        2'b01: begin // half word
          if (data_addr_int[1:0] == 2'b11) begin
            data_misaligned = 1'b1;
          end
        end
      default: ;
      endcase // case (data_type_ex_i)
    end
  end

  assign data_addr_int = adder_result_ex_i;

  assign busy_o = (CS == WAIT_RVALID) | (data_req_o == 1'b1);

  ////////////////
  // Assertions //
  ////////////////
`ifndef VERILATOR
  // make sure there is no new request when the old one is not yet completely done
  // i.e. it should not be possible to get a grant without an rvalid for the
  // last request
  assert property (
    @(posedge clk_i) ((CS == WAIT_RVALID) && (data_gnt_i == 1'b1)) |-> (data_rvalid_i == 1'b1) );

  // there should be no rvalid when we are in IDLE
  assert property ( @(posedge clk_i) (CS == IDLE) |-> (data_rvalid_i == 1'b0) );

  // assert that errors are only sent at the same time as grant
  assert property ( @(posedge clk_i) (data_err_i) |-> (data_gnt_i) );

  // assert that the address does not contain X when request is sent
  assert property ( @(posedge clk_i) (data_req_o) |-> (!$isunknown(data_addr_o)) );
`endif
endmodule
