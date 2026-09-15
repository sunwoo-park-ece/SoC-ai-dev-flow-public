// Portable OPEN_SIM model. PRIVATE_QUARTUS binds the Intel/Altera IMEM IP.
module IMEM #(
    parameter INIT_FILE = ""
) (
    input  wire        aclr,
    input  wire [11:0] address,
    input  wire        clken,
    input  wire        clock,
    output reg  [31:0] q
);
    localparam integer DEPTH = 4096;
    reg [31:0] words [0:DEPTH-1];
    integer i;
    integer image_fd;
    integer line_status;
    integer parse_status;
    integer image_index;
    integer line_number;
    reg [31:0] image_word;
    reg [8*256-1:0] image_line;

    initial begin
        q = 32'h0000_0013;
        for (i = 0; i < DEPTH; i = i + 1)
            words[i] = 32'h0000_0013;

        if (INIT_FILE != "") begin
            image_fd = $fopen(INIT_FILE, "r");
            if (image_fd == 0)
                $fatal(1, "IMEM: requested image cannot be opened: %s", INIT_FILE);

            image_index = 0;
            line_number = 0;
            while (!$feof(image_fd)) begin
                image_line = {8*256{1'b0}};
                line_status = $fgets(image_line, image_fd);
                line_number = line_number + 1;
                if (line_status != 0) begin
                    parse_status = $sscanf(image_line, "%h", image_word);
                    if (parse_status == 1) begin
                        if (image_index >= DEPTH)
                            $fatal(1, "IMEM: image exceeds %0d words at line %0d", DEPTH, line_number);
                        words[image_index] = image_word;
                        image_index = image_index + 1;
                    end else if ((image_line != "\n") && (image_line != "\r\n")) begin
                        $fatal(1, "IMEM: invalid hex word at line %0d", line_number);
                    end
                end
            end
            $fclose(image_fd);
            $display("IMEM: loaded %0d words from %s", image_index, INIT_FILE);
        end
    end

    always @(posedge clock or posedge aclr) begin
        if (aclr)
            q <= 32'h0000_0013;
        else if (clken)
            q <= words[address];
    end
endmodule
