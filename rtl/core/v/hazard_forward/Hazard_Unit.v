`include "../../vh/opcode.vh"
`include "../../vh/csr.vh"
`include "../../vh/trap.vh"

module HazardUnit (
    input clk,
    input clk_enable,
    input reset, 
	 
	 input bus_stall_req,
	 input bus_fault_final,
    input csr_front_hold,
    input csr_front_advance,
    input serial_in_flight,
    input pending_fault,
    input id_fault,
    input ex_fault,
    input mem_fault,
    input trap_service_hold,
    input trap_redirect,

    input wire trap_done,
    input wire csr_ready,
    input wire standby_mode,
    input wire [3:0] trap_status,
    input wire ID_valid,
    input wire EX_valid,
    input wire MEM_valid,
    input wire WB_valid,
    input wire misaligned_instruction_flush,
    input wire misaligned_memory_flush,
    input wire pth_done_flush,

    input wire [4:0] ID_rs1,
    input wire [4:0] ID_rs2,
    input wire [11:0] ID_raw_imm,
    input wire [6:0] ID_opcode,
    input wire [2:0] ID_funct3,
    
    input wire [4:0] MEM_rd,
    input wire MEM_register_write_enable,
    input wire MEM_memory_read,
    input wire MEM_csr_write_enable,
    input wire [11:0] MEM_csr_write_address,       // MEM_imm[11:0]

    input wire [4:0] WB_rd,
    input wire WB_register_write_enable,
    input wire WB_csr_write_enable,
    input wire [11:0] WB_csr_write_address, // WB_imm[11:0]

    input wire [4:0] EX_rd,
    input wire [6:0] EX_opcode,
    input wire [4:0] EX_rs1,
    input wire [4:0] EX_rs2,
    input wire [11:0] EX_imm,  // EX_imm[11:0]

    input wire EX_csr_write_enable,

    input wire EX_jump,
    input wire branch_taken,

    // to Forward Unit
    output reg [1:0] hazard_mem,
    output reg [1:0] hazard_wb,
    output wire csr_hazard_mem,
    output wire csr_hazard_wb,
    
    output wire store_hazard_mem,
    output wire store_hazard_wb,

    output reg IF_ID_flush,
    output reg ID_EX_flush,
    output reg EX_MEM_flush,
    output reg MEM_WB_flush,
    
    output reg IF_ID_stall,
    output reg ID_EX_stall,
    output reg EX_MEM_stall,
    output reg MEM_WB_stall
);
    wire is_store = EX_valid && (EX_opcode == `OPCODE_STORE);
    wire mem_forwardable = MEM_valid && MEM_register_write_enable && !MEM_memory_read;

    function id_uses_rs1;
        input [6:0] op;
        input [2:0] f3;
        begin
            case (op)
                `OPCODE_JALR,
                `OPCODE_BRANCH,
                `OPCODE_LOAD,
                `OPCODE_STORE,
                `OPCODE_ITYPE,
                `OPCODE_RTYPE: id_uses_rs1 = 1'b1;
                `OPCODE_ENVIRONMENT:
                    id_uses_rs1 = (f3 == `CSR_CSRRW) ||
                                  (f3 == `CSR_CSRRS) ||
                                  (f3 == `CSR_CSRRC);
                default: id_uses_rs1 = 1'b0;
            endcase
        end
    endfunction

    function id_uses_rs2;
        input [6:0] op;
        begin
            case (op)
                `OPCODE_BRANCH,
                `OPCODE_STORE,
                `OPCODE_RTYPE: id_uses_rs2 = 1'b1;
                default: id_uses_rs2 = 1'b0;
            endcase
        end
    endfunction

    wire load_use_hazard =
        ID_valid && EX_valid && (EX_opcode == `OPCODE_LOAD) &&
        (EX_rd != 5'd0) &&
        ((id_uses_rs1(ID_opcode, ID_funct3) && (EX_rd == ID_rs1)) ||
         (id_uses_rs2(ID_opcode) && (EX_rd == ID_rs2)));

    wire mem_hazard_rs1 = EX_valid && mem_forwardable && (MEM_rd != 5'd0) && (MEM_rd == EX_rs1);
    wire mem_hazard_rs2 = EX_valid && mem_forwardable && (MEM_rd != 5'd0) && (MEM_rd == EX_rs2);
    wire wb_hazard_rs1 = WB_valid && EX_valid && WB_register_write_enable && (WB_rd != 5'd0) && (WB_rd == EX_rs1);
    wire wb_hazard_rs2 = WB_valid && EX_valid && WB_register_write_enable && (WB_rd != 5'd0) && (WB_rd == EX_rs2);
    
    assign store_hazard_mem = is_store && mem_hazard_rs2;
    assign store_hazard_wb = is_store && wb_hazard_rs2 && !mem_hazard_rs2;
    
    assign csr_hazard_mem = EX_valid && MEM_valid && MEM_csr_write_enable && (MEM_csr_write_address == EX_imm);
    assign csr_hazard_wb = EX_valid && WB_valid && WB_csr_write_enable && (WB_csr_write_address == EX_imm);

    reg [4:0] retire_rd;
    reg [11:0] retire_csr_write_address;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            retire_rd <= 5'b0;
            retire_csr_write_address <= 12'b0;    
        end else if (clk_enable) begin
            retire_rd <= WB_rd;
            retire_csr_write_address <= WB_csr_write_address;
        end
        
    end 

    always @(*) begin
        //csr_reg_hazard = 1'b0;
        hazard_mem = 2'b00;
        hazard_wb = 2'b00;
        IF_ID_flush = 1'b0;
        ID_EX_flush = 1'b0;
        EX_MEM_flush = 1'b0;
        MEM_WB_flush = 1'b0;
        
        IF_ID_stall = 1'b0;
        ID_EX_stall = 1'b0;
        EX_MEM_stall = 1'b0;
        MEM_WB_stall = 1'b0;

        hazard_mem[0] = mem_hazard_rs1;
        hazard_mem[1] = is_store ? 1'b0 : mem_hazard_rs2;
        hazard_wb[0] = wb_hazard_rs1 && !mem_hazard_rs1;
        hazard_wb[1] = is_store ? 1'b0 : (wb_hazard_rs2 && !mem_hazard_rs2);

        // A final ERROR is a completion edge, even if raw stall is asserted.
        if (bus_stall_req && !bus_fault_final) begin
            IF_ID_stall = 1'b1;
            ID_EX_stall = 1'b1;
            EX_MEM_stall = 1'b1;
            MEM_WB_stall = 1'b1;
        end else if (trap_redirect) begin
            // The service owns WB; only its fault/return token is cleared.
            IF_ID_flush = 1'b1;
            MEM_WB_flush = 1'b1;
        end else if (trap_service_hold) begin
            IF_ID_stall = 1'b1;
            ID_EX_stall = 1'b1;
            EX_MEM_stall = 1'b1;
            MEM_WB_stall = 1'b1;
        end else if (mem_fault) begin
            // Preserve the faulting MEM token as the incoming WB owner.
            IF_ID_stall = 1'b1;
            IF_ID_flush = 1'b1;
            ID_EX_flush = 1'b1;
            EX_MEM_flush = 1'b1;
        end else if (ex_fault) begin
            IF_ID_stall = 1'b1;
            IF_ID_flush = 1'b1;
            ID_EX_flush = 1'b1;
        end else if (EX_valid && (branch_taken || EX_jump)) begin
            // An older EX redirect kills a held, younger ID CSR token.
            IF_ID_flush = 1'b1;
            ID_EX_flush = 1'b1;
        end else if (id_fault) begin
            IF_ID_stall = 1'b1;
            IF_ID_flush = 1'b1;
        end else if (csr_front_advance) begin
            IF_ID_stall = 1'b1;
            IF_ID_flush = 1'b1;
        end else if (csr_front_hold) begin
            IF_ID_stall = 1'b1;
            ID_EX_flush = 1'b1;
        end else if (serial_in_flight || pending_fault) begin
            IF_ID_stall = 1'b1;
        end else if (load_use_hazard) begin
            IF_ID_stall = 1'b1;
            ID_EX_flush = 1'b1;
        end
    end


    
endmodule
