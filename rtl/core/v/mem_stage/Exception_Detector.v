`include "../../vh/opcode.vh"
`include "../../vh/store.vh"
`include "../../vh/load.vh"
`include "../../vh/trap.vh"

module ExceptionDetector (
    input clk,
    input clk_enable,
    input reset,
    input [6:0] ID_opcode,            // opcode from ID Phase
    input [31:0] ID_instruction,
    input ID_illegal,
    input [6:0] EX_opcode,            // opcode from EX Phase
    input [6:0] MEM_opcode,           // opcode from MEM Phase for Synchronous Exception Detector
    input [2:0] ID_funct3,                // funct3
    input [2:0] EX_funct3,
    input [2:0] MEM_funct3,
    input [1:0] alu_result,         // LSBs of jump target and data_memory_address
    input EX_branch_taken,
    input [1:0] EX_branch_target,
    input [1:0] MEM_alu_result,
    input [11:0] raw_imm,            // raw_imm field to distinguish EBREAK, ECALL and MRET, CSR_Address
    input [11:0] EX_raw_imm,
    input csr_write_enable,         // CSR WE signal from Control Unit for Detecting Illegal CSR access from ID Phase.
    
    output reg trapped,                // legacy registered diagnostic
    output reg [3:0] trap_status,
    output wire ID_fault_now,
    output wire [3:0] ID_fault_cause,
    output wire EX_fault_now,
    output wire [3:0] EX_fault_cause
);
    reg ID_trapped;
    reg [3:0] ID_trap_status;
    reg EX_trapped;
    reg [3:0] EX_trap_status;
    reg MEM_trapped;
    reg [3:0] MEM_trap_status;
    reg trapped_combinatorial;
    reg [3:0] trap_status_combinatorial;

    // Source-stage faults are transported with the owning instruction token.
    assign ID_fault_now = ID_trapped;
    assign ID_fault_cause = ID_trap_status;
    assign EX_fault_now = EX_trapped;
    assign EX_fault_cause = EX_trap_status;
    
    always @(*) begin
        ID_trap_status = `TRAP_NONE;
        ID_trapped = 1'b0;

        if (ID_illegal) begin
            ID_trapped = 1'b1;
            ID_trap_status = `TRAP_ILLEGAL_INSTRUCTION;
        end else if (ID_instruction == 32'h00000073) begin
            ID_trapped = 1'b1;
            ID_trap_status = `TRAP_ECALL;
        end else if (ID_instruction == 32'h00100073) begin
            ID_trapped = 1'b1;
            ID_trap_status = `TRAP_EBREAK;
        end

        EX_trapped = 1'b0;
        EX_trap_status = `TRAP_NONE;

        case (EX_opcode)
            `OPCODE_BRANCH: begin
                if (EX_branch_taken && EX_branch_target[1]) begin
                    EX_trapped = 1'b1;
                    EX_trap_status = `TRAP_MISALIGNED_INSTRUCTION;
                end
            end

            `OPCODE_STORE: begin
                case (EX_funct3)
                    `STORE_SH: begin
                        if (alu_result[0] == 1'b1) begin
                            EX_trapped = 1'b1;
                            EX_trap_status = `TRAP_MISALIGNED_STORE;
                        end else begin
                            EX_trapped = 1'b0;
                            EX_trap_status = `TRAP_NONE;
                        end
                    end
                    `STORE_SW: begin
                        if (alu_result[1:0] != 2'b00) begin
                            EX_trapped = 1'b1;
                            EX_trap_status = `TRAP_MISALIGNED_STORE;
                        end else begin
                            EX_trapped = 1'b0;
                            EX_trap_status = `TRAP_NONE;
                        end
                    end
                    default: begin
                        EX_trapped = 1'b0;
                        EX_trap_status = `TRAP_NONE;
                    end 
                endcase
            end

            `OPCODE_LOAD: begin
                case (EX_funct3)
                    `LOAD_LH, `LOAD_LHU: begin
                        if (alu_result[0] == 1'b1) begin
                            EX_trapped = 1'b1;
                            EX_trap_status = `TRAP_MISALIGNED_LOAD;
                        end else begin
                            EX_trapped = 1'b0;
                            EX_trap_status = `TRAP_NONE;
                        end
                    end
                    `LOAD_LW: begin
                        if (alu_result[1:0] != 2'b00) begin
                            EX_trapped = 1'b1;
                            EX_trap_status = `TRAP_MISALIGNED_LOAD;
                        end else begin
                            EX_trapped = 1'b0;
                            EX_trap_status = `TRAP_NONE;
                        end
                    end
                    default: begin
                        EX_trapped = 1'b0;
                        EX_trap_status = `TRAP_NONE;
                    end
                endcase
            end
            `OPCODE_JAL, `OPCODE_JALR: begin
                if (alu_result == 2'b0) begin
                    EX_trapped = 1'b0;
                    EX_trap_status = `TRAP_NONE;
                end else begin
                    EX_trapped = 1'b1;
                    EX_trap_status = `TRAP_MISALIGNED_INSTRUCTION;
                end
            end    
            default: begin
                EX_trapped = 1'b0;
                EX_trap_status = `TRAP_NONE;
            end
        endcase

        MEM_trapped = 1'b0;
        MEM_trap_status = `TRAP_NONE;

        case (MEM_opcode)
            `OPCODE_STORE: begin
                case (MEM_funct3)
                    `STORE_SH: begin
                        if (MEM_alu_result[0] == 1'b1) begin
                            MEM_trapped = 1'b1;
                            MEM_trap_status = `TRAP_MISALIGNED_STORE;
                        end else begin
                            MEM_trapped = 1'b0;
                            MEM_trap_status = `TRAP_NONE;
                        end
                    end
                    `STORE_SW: begin
                        if (MEM_alu_result[1:0] != 2'b00) begin
                            MEM_trapped = 1'b1;
                            MEM_trap_status = `TRAP_MISALIGNED_STORE;
                        end else begin
                            MEM_trapped = 1'b0;
                            MEM_trap_status = `TRAP_NONE;
                        end
                    end
                    default: begin
                        MEM_trapped = 1'b0;
                        MEM_trap_status = `TRAP_NONE;
                    end 
                endcase
            end

            `OPCODE_LOAD: begin
                case (MEM_funct3)
                    `LOAD_LH, `LOAD_LHU: begin
                        if (MEM_alu_result[0] == 1'b1) begin
                            MEM_trapped = 1'b1;
                            MEM_trap_status = `TRAP_MISALIGNED_LOAD;
                        end else begin
                            MEM_trapped = 1'b0;
                            MEM_trap_status = `TRAP_NONE;
                        end
                    end
                    `LOAD_LW: begin
                        if (MEM_alu_result[1:0] != 2'b00) begin
                            MEM_trapped = 1'b1;
                            MEM_trap_status = `TRAP_MISALIGNED_LOAD;
                        end else begin
                            MEM_trapped = 1'b0;
                            MEM_trap_status = `TRAP_NONE;
                        end
                    end
                    default: begin
                        MEM_trapped = 1'b0;
                        MEM_trap_status = `TRAP_NONE;
                    end
                endcase
            end
            `OPCODE_JAL, `OPCODE_JALR: begin
                if (MEM_alu_result == 2'b0) begin
                    MEM_trapped = 1'b0;
                    MEM_trap_status = `TRAP_NONE;
                end else begin
                    MEM_trapped = 1'b1;
                    MEM_trap_status = `TRAP_MISALIGNED_INSTRUCTION;
                end
            end    
            default: begin
                MEM_trapped = 1'b0;
                MEM_trap_status = `TRAP_NONE;
            end
        endcase

        if (MEM_trapped) begin
            trapped_combinatorial = 1'b1;
            trap_status_combinatorial = MEM_trap_status;
        end else if (EX_trapped) begin
            trapped_combinatorial = 1'b1;
            trap_status_combinatorial = EX_trap_status;
        end else if (ID_trapped) begin
            trapped_combinatorial = 1'b1;
            trap_status_combinatorial = ID_trap_status;
        end else begin
            trapped_combinatorial = 1'b0;
            trap_status_combinatorial = `TRAP_NONE;
        end
    end

    // Synchronous trap signal output
    always @(posedge clk  or posedge reset) begin
        if (reset) begin
            trapped <= 1'b0;
            trap_status <= `TRAP_NONE;
        end else if (clk_enable) begin
            trapped <= trapped_combinatorial;
            trap_status <= trap_status_combinatorial;
        end
    end
endmodule
