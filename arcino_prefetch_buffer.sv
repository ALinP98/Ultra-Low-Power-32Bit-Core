////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Developer:      Alin Parcalab - alin.parcalab@allengra.eu                  //
//                                                                            //
// Design Name:    Prefetcher Buffer for 32 bit memory interface              //
// Project Name:   ARCINO                                                     //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Prefetch Buffer that caches instructions. This cuts overly //
//                 long critical paths to the instruction cache               //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
/**
 * Prefetcher Buffer for 32 bit memory interface
 *
 * Prefetch Buffer that caches instructions. This cuts overly long critical
 * paths to the instruction cache.
 */
module arcino_prefetch_buffer (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        req_i,

    input  logic        branch_i,
    input  logic [31:0] addr_i,


    input  logic        ready_i,
    output logic        valid_o,
    output logic [31:0] rdata_o,
    output logic [31:0] addr_o,


    // goes to instruction memory / instruction cache
    output logic        instr_req_o,
    input  logic        instr_gnt_i,
    output logic [31:0] instr_addr_o,
    input  logic [31:0] instr_rdata_i,
    input  logic        instr_rvalid_i,

    // Prefetch Buffer Status
    output logic        busy_o
);

  typedef enum logic [1:0] {
    IDLE, WAIT_GNT, WAIT_RVALID, WAIT_ABORTED
  } prefetch_fsm_e;

  prefetch_fsm_e CS, NS;

  logic [31:0] instr_addr_q, fetch_addr;
  logic        addr_valid;

  logic        fifo_valid;
  logic        fifo_ready;
  logic        fifo_clear;

  ////////////////////////////
  // Prefetch buffer status //
  ////////////////////////////

  assign busy_o = (CS != IDLE) | instr_req_o;

  //////////////////////////////////////////////
  // Fetch fifo - consumes addresses and data //
  //////////////////////////////////////////////

  arcino_fetch_fifo fifo_i (
      .clk_i                 ( clk_i             ),
      .rst_ni                ( rst_ni            ),

      .clear_i               ( fifo_clear        ),

      .in_addr_i             ( instr_addr_q      ),
      .in_rdata_i            ( instr_rdata_i     ),
      .in_valid_i            ( fifo_valid        ),
      .in_ready_o            ( fifo_ready        ),


      .out_valid_o           ( valid_o           ),
      .out_ready_i           ( ready_i           ),
      .out_rdata_o           ( rdata_o           ),
      .out_addr_o            ( addr_o            ),

      .out_valid_stored_o    (                   )
  );


  ////////////////
  // Fetch addr //
  ////////////////

  assign fetch_addr = {instr_addr_q[31:2], 2'b00} + 32'd4;
  assign fifo_clear = branch_i;

  //////////////////////////////////////////////////////////////////////////////
  // Instruction fetch FSM -deals with instruction memory / instruction cache //
  //////////////////////////////////////////////////////////////////////////////

  always_comb begin
    instr_req_o   = 1'b0;
    instr_addr_o  = fetch_addr;
    fifo_valid    = 1'b0;
    addr_valid    = 1'b0;
    NS            = CS;

    unique case(CS)
      // default state, not waiting for requested data
      IDLE: begin
        instr_addr_o = fetch_addr;
        instr_req_o  = 1'b0;

        if (branch_i) begin
          instr_addr_o = addr_i;
        end

        if (req_i && (fifo_ready || branch_i )) begin
          instr_req_o = 1'b1;
          addr_valid  = 1'b1;


          //~> granted request or not
          NS = instr_gnt_i ? WAIT_RVALID : WAIT_GNT;
        end
      end // case: IDLE

      // we sent a request but did not yet get a grant
      WAIT_GNT: begin
        instr_addr_o = instr_addr_q;
        instr_req_o  = 1'b1;

        if (branch_i) begin
          instr_addr_o = addr_i;
          addr_valid   = 1'b1;
        end

        //~> granted request or not
        NS = instr_gnt_i ? WAIT_RVALID : WAIT_GNT;
      end // case: WAIT_GNT

      // we wait for rvalid, after that we are ready to serve a new request
      WAIT_RVALID: begin
        instr_addr_o = fetch_addr;

        if (branch_i) begin
          instr_addr_o  = addr_i;
        end

        if (req_i && (fifo_ready || branch_i)) begin
          // prepare for next request

          if (instr_rvalid_i) begin
            instr_req_o = 1'b1;
            fifo_valid  = 1'b1;
            addr_valid  = 1'b1;

            //~> granted request or not
            NS = instr_gnt_i ? WAIT_RVALID : WAIT_GNT;
          end else begin
            // we are requested to abort our current request
            // we didn't get an rvalid yet, so wait for it
            if (branch_i) begin
              addr_valid = 1'b1;
              NS         = WAIT_ABORTED;
            end
          end
        end else begin
          // just wait for rvalid and go back to IDLE, no new request

          if (instr_rvalid_i) begin
            fifo_valid = 1'b1;
            NS         = IDLE;
          end
        end
      end // case: WAIT_RVALID

      // our last request was aborted, but we didn't yet get a rvalid and
      // there was no new request sent yet
      // we assume that req_i is set to high
      WAIT_ABORTED: begin
        instr_addr_o = instr_addr_q;

        if (branch_i) begin
          instr_addr_o = addr_i;
          addr_valid   = 1'b1;
        end

        if (instr_rvalid_i) begin
          instr_req_o  = 1'b1;
          // no need to send address, already done in WAIT_RVALID

          //~> granted request or not
          NS = instr_gnt_i ? WAIT_RVALID : WAIT_GNT;
        end
      end

      default: begin
        // NS          = IDLE;      // unreachable, removing dead code
        // instr_req_o = 1'b0;      // unreachable, removing dead code
      end
    endcase
  end

  ///////////////
  // Registers //
  ///////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      CS              <= IDLE;
      instr_addr_q    <= '0;
    end else begin
      CS              <= NS;

      if (addr_valid) begin
        instr_addr_q    <= instr_addr_o;
      end
    end
  end

endmodule
