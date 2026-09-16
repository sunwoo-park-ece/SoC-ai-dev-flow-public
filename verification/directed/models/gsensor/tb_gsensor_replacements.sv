`timescale 1ns/1ps
module tb_gsensor_replacements;
    reg base_clk = 1'b0;
    reg reset_n = 1'b0;
    reg controller_reset_n = 1'b0;
    reg sensor_int = 1'b0;
    reg sensor_sdo = 1'b0;
    wire delayed_reset;
    wire [15:0] accel_x, accel_y, accel_z;
    wire ready, mosi, cs_n, sclk;
    reg [55:0] captured;
    reg [55:0] response_frame;
    integer bit_count;
    integer transaction;
    reg ready_seen = 1'b0;
    reg [15:0] expected_init [0:10];

    always #5 base_clk = ~base_clk;
    always @(posedge base_clk)
        if (ready) ready_seen <= 1'b1;

    reset_delay #(.DELAY_BITS(3)) u_delay (
        .iRSTN(reset_n), .iCLK(base_clk), .oRST(delayed_reset)
    );

    spi_ee_config #(.POLL_BITS(3)) dut (
        .iRSTN(controller_reset_n), .iPCLK(base_clk),
        .iG_INT2(sensor_int), .out_acc_x(accel_x), .out_acc_y(accel_y),
        .out_acc_z(accel_z), .gsensor_ready(ready), .SPI_SDI(mosi),
        .SPI_SDO(sensor_sdo), .oSPI_CSN(cs_n), .oSPI_CLK(sclk)
    );

    task capture_transaction(input integer bits);
        begin
            captured = 56'd0;
            bit_count = 0;
            if (cs_n)
                @(negedge cs_n);
            while (bit_count < bits) begin
                @(posedge sclk);
                captured = {captured[54:0], mosi};
                bit_count = bit_count + 1;
            end
            @(posedge cs_n);
        end
    endtask

    initial begin
        expected_init[0]=16'h2420; expected_init[1]=16'h2503;
        expected_init[2]=16'h2601; expected_init[3]=16'h277f;
        expected_init[4]=16'h2809; expected_init[5]=16'h2946;
        expected_init[6]=16'h2c09; expected_init[7]=16'h2e00;
        expected_init[8]=16'h2f00; expected_init[9]=16'h3100;
        expected_init[10]=16'h2d08;

        #13; reset_n = 1'b1;
        repeat (7) @(posedge base_clk);
        if (!delayed_reset) $fatal(1, "reset_delay released early");
        @(posedge base_clk); #1;
        if (delayed_reset) $fatal(1, "reset_delay did not release");

        @(negedge base_clk);
        controller_reset_n = 1'b1;

        for (transaction = 0; transaction < 11; transaction = transaction + 1) begin
            capture_transaction(16);
            if (captured[15:0] !== expected_init[transaction])
                $fatal(1, "init[%0d] got=%04x expected=%04x", transaction,
                       captured[15:0], expected_init[transaction]);
        end

        sensor_int = 1'b1;
        response_frame = {8'h00, 48'h3412_7856_bc9a};
        captured = 56'd0;
        bit_count = 0;
        @(negedge cs_n);
        sensor_int = 1'b0;
        while (bit_count < 56) begin
            if (bit_count >= 8) begin
                @(negedge sclk);
                sensor_sdo = response_frame[55-bit_count];
            end
            @(posedge sclk);
            captured = {captured[54:0], mosi};
            bit_count = bit_count + 1;
        end
        @(posedge cs_n); #1;
        if (captured[55:48] !== 8'hf2)
            $fatal(1, "read command got=%02x", captured[55:48]);
        if (!ready_seen) $fatal(1, "sample ready pulse missing");
        if (accel_x !== 16'h1234 || accel_y !== 16'h5678 || accel_z !== 16'h9abc)
            $fatal(1, "axis reconstruction x=%04x y=%04x z=%04x", accel_x, accel_y, accel_z);
        if (!cs_n || sclk !== 1'b1) $fatal(1, "SPI idle state");
        $display("SUMMARY: PASS GSensor replacements");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "GSensor replacement test timeout");
    end
endmodule
