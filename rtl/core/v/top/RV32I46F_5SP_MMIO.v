`include "../../vh/alu_src_select.vh"
`include "../../vh/rf_wd_select.vh"
`include "../../vh/trap.vh"

module RV32I46F5SPMMIO(
    input clk,
    input clk_enable,           // Added: Clock enable signal
    input reset,
    
    output wire [31:0] retire_instruction,

	 
	 output [31:0] debug_X1,
	 output [31:0] debug_X2,
     output [31:0] debug_X3,
	 output [31:0] debug_X4,
	 output [31:0] debug_pc,
	 
	 output        EX_memory_read_AHB,
	 output        EX_memory_write_AHB,
	 output [31:0] EX_alu_result_AHB,
	 output [2:0] EX_funct3_AHB,  
	 
	 output [31:0] data_memory_read_data_AHB,   // HWDATA 
	 	 
	 input   [31:0] HRDATA_FROM_AHB,
	 input   [1:0] HRESP_FROM_AHB,
	 input          HREADY_FROM_AHB,
	 input          bus_stall_req,
	 
	 output [3:0] CUSTOM_WRITE_MASK,

     output oBRAM_HAZARD
);
	
	localparam XLEN = 32;


    // MMIO Interface
    wire mmio_uart_status_hit;
    wire [XLEN-1:0] mmio_uart_status;

    // Program Counter and PC Plus 4
    wire [XLEN-1:0] pc;
    wire [XLEN-1:0] pc_plus_4_signal;
    wire [XLEN-1:0] next_pc;
	 
	 assign debug_pc = next_pc;
    
    // Instruction Memory and Debug Interface
    wire [31:0] im_instruction;
    reg [31:0] instruction;
    wire [6:0] IF_opcode;

    // ROM bypass signals (MEM stage instruction memory access)
    wire [31:0] rom_address;
    wire [31:0] rom_read_data;
 
    assign IF_opcode = instruction[6:0];

    // Instruction Decoder
    wire [6:0] opcode;
    wire [2:0] funct3;
    wire [6:0] funct7;
    wire [4:0] rs1;
    wire [4:0] rs2;
    wire [4:0] rd;
    wire [19:0] raw_imm;
    
    // Immediate Generator
    wire [XLEN-1:0] imm;

    // Control Unit
    wire pc_stall;
    wire jump;
    wire branch;
    wire [1:0] alu_src_A_select;
    wire [2:0] alu_src_B_select;
    wire memory_read;
    wire memory_write;
    wire register_file_write;
    wire [2:0] register_file_write_data_select;
    wire cu_csr_write_enable;

    // Branch Logic and Branch Predictor
    wire branch_taken;
    wire [XLEN-1:0] branch_target;
    wire [XLEN-1:0] branch_target_actual;

    // Register File
    reg [XLEN-1:0] register_file_write_data;
    wire [XLEN-1:0] read_data1;
    wire [XLEN-1:0] read_data2;

    // ALU Controller
    wire [3:0] alu_op;

    // ALU src MUX
    reg [XLEN-1:0] src_A;
    reg [XLEN-1:0] src_B;

    // ALU
    wire [XLEN-1:0] alu_result;
    wire alu_zero;
    
    // Data Memory and Byte Enable Logic
    wire [XLEN-1:0] data_memory_read_data;
    wire [XLEN-1:0] byte_enable_logic_register_file_write_data;
    wire [XLEN-1:0] data_memory_write_data;
    wire [3:0] write_mask;

    // CSR File
    wire [XLEN-1:0] csr_read_out;
    wire csr_rsp_valid;
    wire [1:0] csr_rsp_owner;

    // Exception Detector
    wire trapped;
    wire [3:0] trap_status;
    wire ID_fault_raw;
    wire [3:0] ID_fault_raw_cause;
    wire EX_fault_raw;
    wire [3:0] EX_fault_raw_cause;
    reg access_fault_active;
    wire bus_fault_final = HREADY_FROM_AHB && (HRESP_FROM_AHB == 2'b01) && MEM_valid &&
                           (MEM_memory_read || MEM_memory_write) && !MEM_exc_valid &&
                           !access_fault_active;
    wire bus_wait_hold = bus_stall_req && !bus_fault_final;
    wire trap_redirect_fire;
    wire mret_redirect_fire;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            access_fault_active <= 1'b0;
        end else if (clk_enable) begin
            if (bus_fault_final)
                access_fault_active <= 1'b1;
            else if (trap_redirect_fire)
                access_fault_active <= 1'b0;
        end
    end

    // WB-owned trap/return service replaces the old global trap hold.
    wire trap_service_hold;
    wire trap_wr_valid;
    wire [11:0] trap_wr_addr;
    wire [XLEN-1:0] trap_wr_data;
    wire trap_req_valid;
    wire [11:0] trap_req_addr;
    wire mret_req_valid;
    wire [11:0] mret_req_addr;
    wire trap_rsp_consume;
    wire [XLEN-1:0] trap_target;
    wire trap_wb_clear;
    
    // IF_ID_Register
    wire [XLEN-1:0] ID_pc;
    wire [XLEN-1:0] ID_pc_plus_4;
    wire [31:0] ID_instruction;
    wire ID_valid;

    // ID_EX_Register
    wire [XLEN-1:0] EX_pc;
    wire [XLEN-1:0] EX_pc_plus_4;
    wire [31:0] EX_instruction;
    wire EX_valid;
    wire EX_jump;
    wire EX_memory_read;
    wire EX_memory_write;
    wire [2:0] EX_register_file_write_data_select;
    wire EX_register_write_enable;
    wire EX_csr_write_enable;
    wire EX_branch;
    wire [1:0] EX_alu_src_A_select;
    wire [2:0] EX_alu_src_B_select;
    wire [6:0] EX_opcode;
    wire [2:0] EX_funct3;
    wire [6:0] EX_funct7;
    wire [4:0] EX_rd;
    wire [19:0] EX_raw_imm;
    wire [XLEN-1:0] EX_read_data1;
    wire [XLEN-1:0] EX_read_data2;
    wire [4:0] EX_rs1;
    wire [4:0] EX_rs2;
    wire [XLEN-1:0] EX_imm;
    wire [XLEN-1:0] EX_csr_read_data;

    // EX_MEM_Register
    wire [XLEN-1:0] MEM_pc;
    wire [XLEN-1:0] MEM_pc_plus_4;
    wire [31:0] MEM_instruction;
    wire MEM_valid;
    wire MEM_memory_read;
    wire MEM_memory_write;
    wire [2:0] MEM_register_file_write_data_select;
    wire MEM_register_write_enable;
    wire MEM_csr_write_enable;
    wire [6:0] MEM_opcode;
    wire [2:0] MEM_funct3;
    wire [4:0] MEM_rs1;
    wire [4:0] MEM_rd;
    wire [XLEN-1:0] MEM_read_data2;
    wire [XLEN-1:0] MEM_imm;
    wire [19:0] MEM_raw_imm;
    wire [XLEN-1:0] MEM_csr_read_data;
    wire [XLEN-1:0] MEM_alu_result;

    // MEM_WB_Register
    wire [XLEN-1:0] WB_pc;
    wire [XLEN-1:0] WB_pc_plus_4;
    wire [31:0] WB_instruction;
    wire WB_valid;
    wire [6:0] WB_opcode;
    wire MEM_WB_flush;
    wire [2:0] WB_register_file_write_data_select;
    wire [XLEN-1:0] WB_imm;
    wire [19:0] WB_raw_imm;
    wire [XLEN-1:0] WB_csr_read_data;
    wire [XLEN-1:0] WB_alu_result;
    wire WB_register_write_enable;
    wire WB_csr_write_enable;
    wire [4:0] WB_rs1;
    wire [4:0] WB_rd;
    wire [XLEN-1:0] WB_byte_enable_logic_register_file_write_data;

    // Hazard Unit
    wire IF_ID_flush;
    wire ID_EX_flush;
    wire EX_MEM_flush;
    wire IF_ID_stall;
    wire ID_EX_stall;
    wire EX_MEM_stall;
    wire MEM_WB_stall;
    wire csr_hazard_mem;
    wire csr_hazard_wb;
    wire store_hazard_mem;
    wire store_hazard_wb;

    // Forward Unit
    wire [1:0] hazard_mem;
    wire [1:0] hazard_wb;
    wire [XLEN-1:0] csr_forward_data;
    wire [XLEN-1:0] alu_forward_source_data_a;
    wire [XLEN-1:0] alu_forward_source_data_b;
    wire [1:0] alu_forward_source_select_a;
    wire [1:0] alu_forward_source_select_b;
    reg [XLEN-1:0] alu_normal_source_a;
    reg [XLEN-1:0] alu_normal_source_b;

    reg [XLEN-1:0] retired_alu_result;
    reg [XLEN-1:0] retired_csr_read_data;

    // 3B2A transport metadata follows the exact stage hold/flush decisions.
    reg EX_exc_valid, MEM_exc_valid, WB_exc_valid;
    reg [3:0] EX_exc_cause, MEM_exc_cause, WB_exc_cause;
    reg EX_serial_valid, MEM_serial_valid, WB_serial_valid;
    reg fault_pending;
    wire mem_fault_now = bus_fault_final;
    wire ex_fault_now = EX_valid && !EX_exc_valid && EX_fault_raw &&
                        !mem_fault_now;
    wire ex_redirect_now = EX_valid && !EX_exc_valid && !ex_fault_now &&
                           !mem_fault_now && (EX_jump || branch_taken);
    wire id_fault_now = ID_valid && ID_fault_raw && !fault_pending &&
                        !mem_fault_now && !ex_fault_now && !ex_redirect_now;
    wire [3:0] mem_fault_cause =
        MEM_memory_write ? 4'd9 : 4'd8;

    // Normal architectural retirement happens on the edge that consumes the
    // successful WB owner. A held, faulted, flushed, or MRET service token
    // cannot retire through this path. A younger MEM fault does not kill WB.
    wire wb_is_mret = WB_valid && !WB_exc_valid &&
                      (WB_instruction == 32'h30200073);
    wire wb_normal_consume = clk_enable && !reset && WB_valid &&
                             !WB_exc_valid && !wb_is_mret &&
                             !MEM_WB_stall && !MEM_WB_flush &&
                             !trap_service_hold;
    wire wb_mret_consume = !reset && wb_is_mret && mret_redirect_fire &&
                           !MEM_WB_stall;
    wire commit_valid = wb_normal_consume || wb_mret_consume;
    // Compatibility observation for the 3B2A transport testbenches.
    wire wb_owner_release = wb_normal_consume;

    // One-entry front-end serialization owner. A write-only CSR still
    // traverses the same barrier, but does not issue a physical read.
    localparam [1:0] SER_IDLE = 2'd0, SER_DRAIN = 2'd1,
                     SER_ADVANCE = 2'd2, SER_FLIGHT = 2'd3;
    reg [1:0] serial_state;
    reg serial_is_mret;
    reg serial_needs_read;
    reg [11:0] serial_addr;
    reg drain_empty_seen;
    // Only the explicitly supported RV32I/project-CSR subset is executable.
    // An illegal ID token is carried to WB with all normal effects disabled.
    function automatic instruction_legal;
        input [31:0] insn;
        reg [6:0] op;
        reg [2:0] f3;
        reg [6:0] f7;
        reg [11:0] csr_addr;
        reg csr_known, csr_counter, csr_writable, write_intent;
        begin
            op = insn[6:0];
            f3 = insn[14:12];
            f7 = insn[31:25];
            csr_addr = insn[31:20];
            csr_counter = csr_addr == 12'hB00 || csr_addr == 12'hB02 ||
                          csr_addr == 12'hB80 || csr_addr == 12'hB82;
            csr_writable = csr_addr == 12'h305 || csr_addr == 12'h341 ||
                           csr_addr == 12'h342;
            csr_known = csr_counter || csr_writable || csr_addr == 12'hF11 ||
                        csr_addr == 12'hF12 || csr_addr == 12'hF13 ||
                        csr_addr == 12'hF14 || csr_addr == 12'h300 ||
                        csr_addr == 12'h301;
            write_intent = f3 == 3'b001 || f3 == 3'b101 ||
                           ((f3 == 3'b010 || f3 == 3'b011 ||
                             f3 == 3'b110 || f3 == 3'b111) &&
                            insn[19:15] != 5'd0);
            instruction_legal = 1'b0;
            case (op)
                7'h37, 7'h17, 7'h6F: instruction_legal = 1'b1;
                7'h67: instruction_legal = f3 == 3'b000;
                7'h63: instruction_legal = f3 == 3'b000 || f3 == 3'b001 ||
                                               f3 == 3'b100 || f3 == 3'b101 ||
                                               f3 == 3'b110 || f3 == 3'b111;
                7'h03: instruction_legal = f3 == 3'b000 || f3 == 3'b001 ||
                                               f3 == 3'b010 || f3 == 3'b100 ||
                                               f3 == 3'b101;
                7'h23: instruction_legal = f3 == 3'b000 || f3 == 3'b001 ||
                                               f3 == 3'b010;
                7'h13: instruction_legal =
                    (f3 == 3'b001) ? (f7 == 7'b0000000) :
                    (f3 == 3'b101) ? (f7 == 7'b0000000 ||
                                       f7 == 7'b0100000) : 1'b1;
                7'h33: instruction_legal = f7 == 7'b0000000 ||
                          (f7 == 7'b0100000 &&
                           (f3 == 3'b000 || f3 == 3'b101));
                7'h0F: instruction_legal =
                    (f3 == 3'b000 && insn[19:15] == 5'd0 &&
                     insn[11:7] == 5'd0) || insn == 32'h0000100F;
                7'h73: begin
                    if (f3 == 3'b000)
                        instruction_legal = insn == 32'h00000073 ||
                                            insn == 32'h00100073 ||
                                            insn == 32'h30200073;
                    else if (f3 != 3'b100 && csr_known)
                        instruction_legal = !write_intent || csr_writable ||
                                            csr_counter;
                end
                default: instruction_legal = 1'b0;
            endcase
        end
    endfunction
    wire id_instruction_illegal = !instruction_legal(ID_instruction);
    wire id_csr_funct = (funct3 == 3'b001 || funct3 == 3'b010 ||
                         funct3 == 3'b011 || funct3 == 3'b101 ||
                         funct3 == 3'b110 || funct3 == 3'b111);
    wire id_csr_supported =
        raw_imm[11:0] == 12'hB00 || raw_imm[11:0] == 12'hB02 ||
        raw_imm[11:0] == 12'hB80 || raw_imm[11:0] == 12'hB82 ||
        raw_imm[11:0] == 12'hF11 || raw_imm[11:0] == 12'hF12 ||
        raw_imm[11:0] == 12'hF13 || raw_imm[11:0] == 12'hF14 ||
        raw_imm[11:0] == 12'h300 || raw_imm[11:0] == 12'h301 ||
        raw_imm[11:0] == 12'h305 || raw_imm[11:0] == 12'h341 ||
        raw_imm[11:0] == 12'h342;
    wire id_is_csr = ID_valid && !id_instruction_illegal &&
                     (opcode == 7'h73) && id_csr_funct && id_csr_supported;
    wire id_is_mret = ID_valid && (ID_instruction == 32'h30200073);
    wire id_csr_write_intent =
        id_is_csr &&
        ((funct3 == 3'b001 || funct3 == 3'b101) ||
         (rs1 != 5'd0 &&
          (funct3 == 3'b010 || funct3 == 3'b011 ||
           funct3 == 3'b110 || funct3 == 3'b111)));
    wire serial_kill = mem_fault_now || ex_fault_now || ex_redirect_now ||
                       id_fault_now;
    wire serial_first = (serial_state == SER_IDLE) &&
                        (id_is_csr || id_is_mret) && !fault_pending &&
                        !serial_kill && !trap_service_hold;
    wire older_empty = !EX_valid && !MEM_valid && !WB_valid &&
                       !bus_wait_hold && !trap_service_hold;
    wire normal_csr_req = clk_enable && (serial_state == SER_DRAIN) &&
                          !serial_is_mret && serial_needs_read &&
                          older_empty && drain_empty_seen && !serial_kill;
    wire serial_response_ready = serial_is_mret || !serial_needs_read ||
        (csr_rsp_valid && csr_rsp_owner == 2'b01);
    wire serial_advance = clk_enable && (serial_state == SER_ADVANCE) &&
                          serial_response_ready && !bus_wait_hold &&
                          !serial_kill;
    wire csr_front_hold = serial_first ||
                          (serial_state == SER_DRAIN) ||
                          ((serial_state == SER_ADVANCE) && !serial_advance);
    wire serial_in_flight = (serial_state == SER_FLIGHT);
    wire normal_csr_rsp_consume = serial_advance && !serial_is_mret &&
                                  serial_needs_read;
    wire csr_rsp_consume = normal_csr_rsp_consume || trap_rsp_consume;
    wire [XLEN-1:0] owned_id_csr_data =
        (serial_needs_read && !serial_is_mret) ? csr_read_out : 32'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            EX_exc_valid <= 1'b0;
            MEM_exc_valid <= 1'b0;
            WB_exc_valid <= 1'b0;
            EX_exc_cause <= 4'b0;
            MEM_exc_cause <= 4'b0;
            WB_exc_cause <= 4'b0;
            EX_serial_valid <= 1'b0;
            MEM_serial_valid <= 1'b0;
            WB_serial_valid <= 1'b0;
            fault_pending <= 1'b0;
            serial_state <= SER_IDLE;
            serial_is_mret <= 1'b0;
            serial_needs_read <= 1'b0;
            serial_addr <= 12'b0;
            drain_empty_seen <= 1'b0;
        end else if (clk_enable) begin
            if (ID_EX_flush) begin
                EX_exc_valid <= 1'b0;
                EX_exc_cause <= 4'b0;
                EX_serial_valid <= 1'b0;
            end else if (!ID_EX_stall) begin
                EX_exc_valid <= id_fault_now;
                EX_exc_cause <= id_fault_now ? ID_fault_raw_cause : 4'b0;
                EX_serial_valid <= serial_advance;
            end
            if (EX_MEM_flush) begin
                MEM_exc_valid <= 1'b0;
                MEM_exc_cause <= 4'b0;
                MEM_serial_valid <= 1'b0;
            end else if (!EX_MEM_stall) begin
                MEM_exc_valid <= EX_valid && (EX_exc_valid || ex_fault_now);
                MEM_exc_cause <= EX_exc_valid ? EX_exc_cause :
                                 ex_fault_now ? EX_fault_raw_cause : 4'b0;
                MEM_serial_valid <= EX_valid && EX_serial_valid;
            end
            if (MEM_WB_flush) begin
                WB_exc_valid <= 1'b0;
                WB_exc_cause <= 4'b0;
                WB_serial_valid <= 1'b0;
            end else if (!MEM_WB_stall) begin
                WB_exc_valid <= MEM_valid && (MEM_exc_valid || mem_fault_now);
                WB_exc_cause <= MEM_exc_valid ? MEM_exc_cause :
                                mem_fault_now ? mem_fault_cause : 4'b0;
                WB_serial_valid <= MEM_valid && MEM_serial_valid;
            end
            if (trap_redirect_fire)
                fault_pending <= 1'b0;
            else if (!bus_wait_hold &&
                     (mem_fault_now || ex_fault_now || id_fault_now))
                fault_pending <= 1'b1;

            if (!bus_wait_hold) begin
                case (serial_state)
                    SER_IDLE: if (serial_first) begin
                        serial_state <= SER_DRAIN;
                        drain_empty_seen <= 1'b0;
                        serial_is_mret <= id_is_mret;
                        serial_needs_read <= id_is_csr &&
                            !((funct3 == 3'b001 || funct3 == 3'b101) &&
                              rd == 5'd0);
                        serial_addr <= raw_imm[11:0];
                    end
                    SER_DRAIN: begin
                        if (serial_kill) begin
                            serial_state <= SER_IDLE;
                            drain_empty_seen <= 1'b0;
                        end else if (!older_empty)
                            drain_empty_seen <= 1'b0;
                        else if (!drain_empty_seen)
                            drain_empty_seen <= 1'b1;
                        else
                            serial_state <= SER_ADVANCE;
                    end
                    SER_ADVANCE: begin
                        if (serial_kill) begin
                            serial_state <= SER_IDLE;
                            drain_empty_seen <= 1'b0;
                        end else if (serial_advance)
                            serial_state <= SER_FLIGHT;
                    end
                    SER_FLIGHT: begin
                        if (trap_redirect_fire ||
                            (WB_serial_valid && commit_valid))
                            serial_state <= SER_IDLE;
                    end
                    default: serial_state <= SER_IDLE;
                endcase
            end
        end
    end

    wire [XLEN-1:0] store_forward_data;
    wire store_forward_enable;
    wire [XLEN-1:0] EX_read_data2_MUX;
    assign EX_read_data2_MUX = store_forward_enable ? store_forward_data : EX_read_data2;
    wire [XLEN-1:0] ex_jump_target =
        (EX_opcode == 7'h67) ? {alu_result[31:1], 1'b0} : alu_result;

   
    
    // Output
    assign retire_instruction = WB_instruction;

    wire normal_csr_write = commit_valid && !wb_is_mret && WB_serial_valid &&
                            (WB_opcode == 7'h73) && WB_csr_write_enable;
    wire gpr_commit = commit_valid && !wb_is_mret &&
                      WB_register_write_enable &&
                      (WB_rd != 5'd0);


	 
	 
  

    // Module instances

    ALU alu (
        .src_A(src_A),
        .src_B(src_B),
        .alu_op(alu_op),

        .alu_result(alu_result),
        .alu_zero(alu_zero)
    );

    ALUController alu_controller (
        .opcode(EX_opcode),
        .funct3(EX_funct3),
        .funct7_5(EX_funct7[5]),
        .imm_10(EX_imm[10]),
    
        .alu_op(alu_op)
    );

    BranchLogic branch_logic (
        .branch(EX_branch),
        .funct3(EX_funct3),
        .src_A(src_A),
        .src_B(src_B),
        .pc(EX_pc),
        .imm(EX_imm),
    
        .branch_taken(branch_taken),
        .branch_target_actual(branch_target_actual)
    );

	 /*
    BranchPredictor #(.XLEN(XLEN)) branch_predictor (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .IF_opcode(IF_opcode),
        .IF_pc(pc),
        .IF_imm(IF_imm),
        .EX_branch(EX_branch),
        .EX_branch_taken(branch_taken),

        .branch_estimation(branch_estimation),
        .branch_target(branch_target)
    );
    */

	 
    StoreAligner store_aligner (
    .memory_write            (MEM_valid && MEM_memory_write &&
                              !MEM_exc_valid && !mem_fault_now),
    .funct3                  (MEM_funct3),
    .register_file_read_data (MEM_read_data2), // Forwarding 된 데이터 적용!
    .address                 (MEM_alu_result[1:0]),

    .data_memory_write_data  (data_memory_write_data),
    .write_mask              (CUSTOM_WRITE_MASK)
    );

	 
    LoadExtender load_extender (
    .memory_read              (MEM_valid && MEM_memory_read &&
                               !MEM_exc_valid && !mem_fault_now),
    .funct3                   (MEM_funct3),
    .data_memory_read_data    (HRDATA_FROM_AHB), // AHB_BRAM에서 나온 데이터
    .address                  (MEM_alu_result[1:0]),

    .register_file_write_data (byte_enable_logic_register_file_write_data) // Forward Unit으로 감
    );


    ControlUnit control_unit (
        .write_done(1'b1),
        .opcode(opcode),
        .funct3(funct3),
        .trap_done(1'b1),
        .csr_ready(1'b1),
        .IF_ID_stall(IF_ID_stall),

        .pc_stall(pc_stall),
        .jump(jump),
        .branch(branch),
        .alu_src_A_select(alu_src_A_select),
        .alu_src_B_select(alu_src_B_select),
        .register_file_write(register_file_write),
        .register_file_write_data_select(register_file_write_data_select),
        .memory_read(memory_read),
        .memory_write(memory_write),
        .csr_write_enable(cu_csr_write_enable)
    );

    CSRFile #(.XLEN(XLEN)) csr_file (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .normal_req_valid(normal_csr_req),
        .normal_req_addr(serial_addr),
        .trap_req_valid(trap_req_valid),
        .trap_req_addr(trap_req_addr),
        .mret_req_valid(mret_req_valid),
        .mret_req_addr(mret_req_addr),
        .rsp_consume(csr_rsp_consume),
        .normal_wr_valid(normal_csr_write),
        .normal_wr_addr(WB_raw_imm[11:0]),
        .normal_wr_data(WB_alu_result),
        .trap_wr_valid(trap_wr_valid),
        .trap_wr_addr(trap_wr_addr),
        .trap_wr_data(trap_wr_data),
        .commit_valid(commit_valid),

        .csr_read_out(csr_read_out),
        .csr_rsp_valid(csr_rsp_valid),
        .csr_rsp_owner(csr_rsp_owner)
    );



    ExceptionDetector exception_detector (
        .clk(clk),
        .clk_enable(clk_enable && !bus_wait_hold),
        .reset(reset),
        .ID_opcode(opcode),
        .ID_instruction(ID_instruction),
        .ID_illegal(id_instruction_illegal),
        .ID_funct3(funct3),
        .EX_opcode(EX_opcode),
        .EX_funct3(EX_funct3),
        .MEM_opcode(MEM_opcode),
        .MEM_funct3(MEM_funct3),
        .raw_imm(raw_imm[11:0]),
        .EX_raw_imm(EX_raw_imm[11:0]),
        .csr_write_enable(cu_csr_write_enable),
        .alu_result(ex_jump_target[1:0]),
        .EX_branch_taken(branch_taken),
        .EX_branch_target(branch_target_actual[1:0]),
        .MEM_alu_result(MEM_alu_result[1:0]),
        //.branch_target_lsbs(branch_target[1:0]),  // 분기 예측기에서 보내는 PC의 정렬X 트랩
        //.branch_estimation(branch_estimation),    // ID 스테이지에서의 분기 예측 신호

        .trapped(trapped),
        .trap_status(trap_status),
        .ID_fault_now(ID_fault_raw),
        .ID_fault_cause(ID_fault_raw_cause),
        .EX_fault_now(EX_fault_raw),
        .EX_fault_cause(EX_fault_raw_cause)
    );

    ForwardUnit forward_unit (
        .hazard_mem(hazard_mem),
        .hazard_wb(hazard_wb),
        .MEM_imm(MEM_imm),
        .MEM_alu_result(MEM_alu_result),
        .MEM_csr_read_data(MEM_csr_read_data),
        .byte_enable_logic_register_file_write_data(byte_enable_logic_register_file_write_data),
        .MEM_pc_plus_4(MEM_pc_plus_4),
        .MEM_opcode(MEM_opcode),
        .WB_opcode(WB_opcode),
        .WB_imm(WB_imm),
        .WB_alu_result(WB_alu_result),
        .WB_csr_read_data(WB_csr_read_data),
        .WB_byte_enable_logic_register_file_write_data(WB_byte_enable_logic_register_file_write_data),
        .WB_pc_plus_4(WB_pc_plus_4),
        .alu_forward_source_data_a(alu_forward_source_data_a),
        .alu_forward_source_data_b(alu_forward_source_data_b),
        .alu_forward_source_select_a(alu_forward_source_select_a),
        .alu_forward_source_select_b(alu_forward_source_select_b),

        .store_forward_data(store_forward_data),
        .store_forward_enable(store_forward_enable),

        .csr_hazard_mem(csr_hazard_mem),
        .csr_hazard_wb(csr_hazard_wb),
        .MEM_csr_write_data(MEM_alu_result),
        .WB_csr_write_data(WB_alu_result),
        .store_hazard_mem(store_hazard_mem),
        .store_hazard_wb(store_hazard_wb),
        .csr_read_data(csr_read_out),

        .csr_forward_data(csr_forward_data)
    );

    HazardUnit hazard_unit (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
		  
		.bus_stall_req(bus_stall_req),
		.bus_fault_final(bus_fault_final),
        .csr_front_hold(csr_front_hold),
        .csr_front_advance(serial_advance),
        .serial_in_flight(serial_in_flight),
        .pending_fault(fault_pending),
        .id_fault(id_fault_now),
        .ex_fault(ex_fault_now),
        .mem_fault(mem_fault_now),
        .trap_service_hold(trap_service_hold),
        .trap_redirect(trap_redirect_fire),
		.ID_valid(ID_valid),
		.EX_valid(EX_valid),
		.MEM_valid(MEM_valid),
		.WB_valid(WB_valid),
		  
        .trap_done(1'b1),
        .standby_mode(1'b0),
        .trap_status(4'b0),
        .misaligned_instruction_flush(1'b0),
        .misaligned_memory_flush(1'b0),
        .pth_done_flush(1'b0),
        .csr_ready(1'b1),
        .ID_rs1(rs1),
        .ID_rs2(rs2),
        .ID_raw_imm(raw_imm[11:0]),
        .ID_opcode(opcode),
        .ID_funct3(funct3),
        .EX_csr_write_enable(EX_csr_write_enable),
        .MEM_rd(MEM_rd),
        .MEM_register_write_enable(MEM_register_write_enable),
        .MEM_memory_read(MEM_memory_read),
        .MEM_csr_write_enable(MEM_csr_write_enable),
        .MEM_csr_write_address(MEM_raw_imm[11:0]),
        .WB_rd(WB_rd),
        .WB_register_write_enable(WB_register_write_enable),
        .WB_csr_write_enable(WB_csr_write_enable),
        .WB_csr_write_address(WB_raw_imm[11:0]),
        .EX_rs1(EX_rs1),
        .EX_rs2(EX_rs2),
        .EX_rd(EX_rd),
        .EX_opcode(EX_opcode),
        .EX_imm(EX_raw_imm[11:0]),
        .branch_taken(branch_taken),
        .EX_jump(EX_jump),

        .hazard_mem(hazard_mem),
        .hazard_wb(hazard_wb),
        .csr_hazard_mem(csr_hazard_mem),
        .csr_hazard_wb(csr_hazard_wb),
        .store_hazard_mem(store_hazard_mem),
        .store_hazard_wb(store_hazard_wb),

        .IF_ID_flush(IF_ID_flush),
        .ID_EX_flush(ID_EX_flush),
        .EX_MEM_flush(EX_MEM_flush),
        .MEM_WB_flush(MEM_WB_flush),
        .IF_ID_stall(IF_ID_stall),
        .ID_EX_stall(ID_EX_stall),
        .EX_MEM_stall(EX_MEM_stall),
        .MEM_WB_stall(MEM_WB_stall)
    );

    ImmediateGenerator immediate_generator (
        .raw_imm(raw_imm),
        .opcode(opcode),
        .imm(imm)
    );

    InstructionDecoder instruction_decoder (
        .instruction(instruction),
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .rs1(rs1),
        .rs2(rs2),
        .rd(rd),
        .raw_imm(raw_imm)
    );

    /*
    InstructionMemory instruction_memory (
        .pc(pc),
        .instruction(im_instruction),
		.clk(clk)
    );
    */


    ProgramCounter program_counter (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .next_pc(next_pc),
        .pc(pc)
    );

    PCPlus4 pc_plus_4 (
        .pc(pc),
        .pc_plus_4(pc_plus_4_signal)
    );

    PCController pc_controller (
        .jump(EX_valid && EX_jump && !EX_exc_valid && !ex_fault_now &&
              !mem_fault_now && !fault_pending),
        .branch_taken(EX_valid && branch_taken && !EX_exc_valid &&
                      !ex_fault_now && !mem_fault_now && !fault_pending),
        .trapped(trap_redirect_fire),
        .pc(pc),
        .jump_target(ex_jump_target),
        .branch_target_actual(branch_target_actual),
        .trap_target(trap_target),
        .pc_stall(pc_stall),
        .next_pc(next_pc)
    );

    RegisterFile register_file (
        .clk(clk),
        .clk_enable(clk_enable),
        .read_reg1(rs1),
        .read_reg2(rs2),
        .write_reg(WB_rd),
        .write_data(register_file_write_data),
        .write_enable(gpr_commit),
    
        .read_data1(read_data1),
        .read_data2(read_data2),
		  	.debug_X1(debug_X1),
	      .debug_X2(debug_X2),
         .debug_X3(debug_X3),
	      .debug_X4(debug_X4),
			.debug_reset(reset)
    );

    WBServiceController trap_controller (
        .clk(clk),
        .clk_enable(clk_enable && !bus_wait_hold),
        .reset(reset),
        .WB_valid(WB_valid),
        .WB_exc_valid(WB_exc_valid),
        .WB_exc_cause(WB_exc_cause),
        .WB_pc(WB_pc),
        .WB_is_mret(wb_is_mret),
        .csr_rsp_valid(csr_rsp_valid),
        .csr_rsp_owner(csr_rsp_owner),
        .csr_rsp_data(csr_read_out),
        .service_hold(trap_service_hold),
        .trap_wr_valid(trap_wr_valid),
        .trap_wr_addr(trap_wr_addr),
        .trap_wr_data(trap_wr_data),
        .trap_req_valid(trap_req_valid),
        .trap_req_addr(trap_req_addr),
        .mret_req_valid(mret_req_valid),
        .mret_req_addr(mret_req_addr),
        .csr_rsp_consume(trap_rsp_consume),
        .redirect_fire(trap_redirect_fire),
        .mret_redirect_fire(mret_redirect_fire),
        .redirect_target(trap_target),
        .wb_clear(trap_wb_clear)
    );

    IF_ID_Register #(.XLEN(XLEN)) if_id_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .flush(IF_ID_flush),
        .IF_ID_stall(IF_ID_stall),

        .IF_pc(pc),
        .IF_pc_plus_4(pc_plus_4_signal),

        .ID_pc(ID_pc),
        .ID_pc_plus_4(ID_pc_plus_4),
        .ID_instruction(ID_instruction),
        .ID_valid(ID_valid)
    );

    ID_EX_Register #(.XLEN(XLEN)) id_ex_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .flush(ID_EX_flush),
        .ID_EX_stall(ID_EX_stall),
        
        .ID_pc(ID_pc),
        .ID_pc_plus_4(ID_pc_plus_4),
        .ID_instruction(ID_instruction),
        .ID_valid(ID_valid),

        .ID_jump(ID_valid && jump && !id_fault_now),
        .ID_branch(ID_valid && branch && !id_fault_now),
        .ID_alu_src_A_select(alu_src_A_select),
        .ID_alu_src_B_select(alu_src_B_select),
        .ID_memory_read(ID_valid && memory_read && !id_fault_now),
        .ID_memory_write(ID_valid && memory_write && !id_fault_now),
        .ID_register_file_write_data_select(register_file_write_data_select),
        .ID_register_write_enable(ID_valid && register_file_write &&
                                  !id_fault_now && !id_is_mret),
        .ID_csr_write_enable(ID_valid && id_csr_write_intent &&
                             !id_fault_now),
        .ID_opcode(opcode), 
        .ID_funct3(funct3),
        .ID_funct7(funct7),
        .ID_rd(rd),
        .ID_raw_imm(raw_imm),
        .ID_read_data1(read_data1),
        .ID_read_data2(read_data2),
        .ID_rs1(rs1),
        .ID_rs2(rs2),
        .ID_imm(imm),
        .ID_csr_read_data(owned_id_csr_data),

        .EX_pc(EX_pc),
        .EX_pc_plus_4(EX_pc_plus_4),
        .EX_instruction(EX_instruction),
        .EX_valid(EX_valid),
        .EX_jump(EX_jump),
        .EX_branch(EX_branch),
        .EX_alu_src_A_select(EX_alu_src_A_select),
        .EX_alu_src_B_select(EX_alu_src_B_select),
        .EX_memory_read(EX_memory_read),
        .EX_memory_write(EX_memory_write),
        .EX_register_file_write_data_select(EX_register_file_write_data_select),
        .EX_register_write_enable(EX_register_write_enable),
        .EX_csr_write_enable(EX_csr_write_enable),
        .EX_opcode(EX_opcode),
        .EX_funct3(EX_funct3),
        .EX_funct7(EX_funct7),
        .EX_rd(EX_rd),
        .EX_raw_imm(EX_raw_imm),
        .EX_read_data1(EX_read_data1),
        .EX_read_data2(EX_read_data2),
        .EX_rs1(EX_rs1),
        .EX_rs2(EX_rs2),
        .EX_imm(EX_imm),
        .EX_csr_read_data(EX_csr_read_data)
    );


	 
    EX_MEM_Register #(.XLEN(XLEN)) ex_mem_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .flush(EX_MEM_flush),
        .EX_MEM_stall(EX_MEM_stall),

        .EX_pc(EX_pc),
        .EX_pc_plus_4(EX_pc_plus_4),
        .EX_instruction(EX_instruction),
        .EX_valid(EX_valid),

        .EX_memory_read(EX_memory_read && !EX_exc_valid && !ex_fault_now),
        .EX_memory_write(EX_memory_write && !EX_exc_valid && !ex_fault_now),
        .EX_register_file_write_data_select(EX_register_file_write_data_select),
        .EX_register_write_enable(EX_register_write_enable && !EX_exc_valid &&
                                  !ex_fault_now),
        .EX_csr_write_enable(EX_csr_write_enable && !EX_exc_valid &&
                             !ex_fault_now),
        .EX_opcode(EX_opcode),
        .EX_funct3(EX_funct3),
        .EX_rs1(EX_rs1),
        .EX_rd(EX_rd),
        .EX_raw_imm(EX_raw_imm),
        .EX_read_data2(EX_read_data2_MUX),
        .EX_imm(EX_imm),
        .EX_csr_read_data(EX_csr_read_data),
        .EX_alu_result(alu_result),

        .MEM_pc(MEM_pc),
        .MEM_pc_plus_4(MEM_pc_plus_4),
        .MEM_instruction(MEM_instruction),
        .MEM_valid(MEM_valid),
        .MEM_memory_read(MEM_memory_read),
        .MEM_memory_write(MEM_memory_write),
        .MEM_register_file_write_data_select(MEM_register_file_write_data_select),
        .MEM_register_write_enable(MEM_register_write_enable),
        .MEM_csr_write_enable(MEM_csr_write_enable),
        .MEM_opcode(MEM_opcode),
        .MEM_funct3(MEM_funct3),
        .MEM_rs1(MEM_rs1),
        .MEM_rd(MEM_rd),
        .MEM_raw_imm(MEM_raw_imm),
        .MEM_read_data2(MEM_read_data2),
        .MEM_imm(MEM_imm),
        .MEM_csr_read_data(MEM_csr_read_data),
        .MEM_alu_result(MEM_alu_result)
    );

    MEM_WB_Register #(.XLEN(XLEN)) mem_wb_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .MEM_WB_stall(MEM_WB_stall),
        .flush(MEM_WB_flush),

        .MEM_pc(MEM_pc),
        .MEM_pc_plus_4(MEM_pc_plus_4),
        .MEM_instruction(MEM_instruction),
        .MEM_valid(MEM_valid),

        .MEM_register_file_write_data_select(MEM_register_file_write_data_select),
        .MEM_imm(MEM_imm),
        .MEM_csr_read_data(MEM_csr_read_data),
        .MEM_alu_result(MEM_alu_result),
        .MEM_register_write_enable(MEM_register_write_enable &&
                                   !MEM_exc_valid && !mem_fault_now),
        .MEM_csr_write_enable(MEM_csr_write_enable &&
                              !MEM_exc_valid && !mem_fault_now),
        .MEM_rs1(MEM_rs1),
        .MEM_rd(MEM_rd),
        .MEM_raw_imm(MEM_raw_imm),
        .MEM_opcode(MEM_opcode),
        .MEM_byte_enable_logic_register_file_write_data(byte_enable_logic_register_file_write_data),

        .WB_pc(WB_pc),
        .WB_pc_plus_4(WB_pc_plus_4),
        .WB_instruction(WB_instruction),
        .WB_valid(WB_valid),
        .WB_register_file_write_data_select(WB_register_file_write_data_select),
        .WB_imm(WB_imm),
        .WB_csr_read_data(WB_csr_read_data),
        .WB_alu_result(WB_alu_result),
        .WB_register_write_enable(WB_register_write_enable),
        .WB_csr_write_enable(WB_csr_write_enable),
        .WB_rs1(WB_rs1),
        .WB_rd(WB_rd),
        .WB_raw_imm(WB_raw_imm),
        .WB_opcode(WB_opcode),
        .WB_byte_enable_logic_register_file_write_data(WB_byte_enable_logic_register_file_write_data)
    );
    
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            retired_alu_result <= {XLEN{1'b0}};
            retired_csr_read_data <= {XLEN{1'b0}};
        end else if (clk_enable) begin
            retired_alu_result <= WB_alu_result;
            retired_csr_read_data <= WB_csr_read_data;
        end
    end
    
    always @(*) begin
        // ALU Source A selection
        case (EX_alu_src_A_select)
            `ALU_SRC_A_RD1: alu_normal_source_a = EX_read_data1;
            `ALU_SRC_A_PC:  alu_normal_source_a = EX_pc;
            `ALU_SRC_A_RS1: alu_normal_source_a = {27'b0, EX_rs1};
            default:        alu_normal_source_a = 32'b0;
        endcase

        // ALU Source B selection
        case (EX_alu_src_B_select)
            `ALU_SRC_B_RD2:   alu_normal_source_b = EX_read_data2;
            `ALU_SRC_B_IMM:   alu_normal_source_b = EX_imm;
            `ALU_SRC_B_SHAMT: alu_normal_source_b = {27'b0, EX_imm[4:0]};
            `ALU_SRC_B_CSR:   alu_normal_source_b = csr_forward_data;
            default:          alu_normal_source_b = 32'b0;
        endcase

        instruction = ID_instruction;

        // Register file write data selection
        case (WB_register_file_write_data_select)
            `RF_WD_LOAD: register_file_write_data = WB_byte_enable_logic_register_file_write_data;
            `RF_WD_ALU:  register_file_write_data = WB_alu_result;
            `RF_WD_LUI:  register_file_write_data = WB_imm;
            `RF_WD_JUMP: register_file_write_data = WB_pc_plus_4;
            `RF_WD_CSR:  register_file_write_data = WB_csr_read_data;
            default:     register_file_write_data = 32'b0;
        endcase

        // ALU forwarding MUX
        case (alu_forward_source_select_a)
            2'b10:   src_A = alu_forward_source_data_a;
            2'b11:   src_A = alu_forward_source_data_a;
            default: src_A = alu_normal_source_a;
        endcase

        case (alu_forward_source_select_b)
            2'b10:   src_B = alu_forward_source_data_b;
            2'b11:   src_B = alu_forward_source_data_b;
            default: src_B = alu_normal_source_b;
        endcase
    end

	 
	 	assign EX_memory_read_AHB  = EX_valid && EX_memory_read &&
                                     !EX_exc_valid && !ex_fault_now &&
                                     !mem_fault_now;
		assign EX_memory_write_AHB = EX_valid && EX_memory_write &&
                                     !EX_exc_valid && !ex_fault_now &&
                                     !mem_fault_now;
	    assign EX_alu_result_AHB       = alu_result;
	    assign EX_funct3_AHB           = EX_funct3;
	 

        
        assign oBRAM_HAZARD = (EX_memory_read_AHB && MEM_valid &&
                               MEM_memory_write && !MEM_exc_valid &&
                               (alu_result[31:2] == MEM_alu_result[31:2]));

	    assign data_memory_read_data_AHB = data_memory_write_data;   // HWDATA  = store라이너의 입력으로 들어갔던 신호.

 
endmodule
