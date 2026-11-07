library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- Standalone production ICB entity. The wrapper and its completion signals
-- are absent from this lane. No test signal drives an internal DUT node.
entity p13_08_d08_icb_tb is
    generic (cycles : positive := 64; negative : boolean := false);
end entity;

architecture test of p13_08_d08_icb_tb is
    signal clk : std_logic := '0';
    signal reset : std_logic := '1';
    signal start : std_logic := '0';
    signal active, overflow : std_logic;
    signal block_value : std_logic_vector(127 downto 0);
    constant iv : std_logic_vector(95 downto 0) := x"ffffffffffffffffffffffff";
begin
    clk <= not clk after 10 ns;
    dut : entity work.aes_icb
        port map (reset, clk, start, '0', start, iv, '0',
                  active, block_value, overflow);

    process
        variable expected : unsigned(31 downto 0) := to_unsigned(1, 32);
        variable observed : std_logic;
        variable expected_overflow : std_logic;
        variable count : unsigned(32 downto 0) := (others => '0');
        variable budget : unsigned(32 downto 0);
    begin
        -- 64 is the smoke budget; the Owner can select the full 2**32-1 budget.
        if cycles = 1 then
            budget := resize(unsigned'(x"ffffffff"), budget'length);
        else
            budget := to_unsigned(cycles, budget'length);
        end if;
        wait until falling_edge(clk);
        reset <= '0';
        start <= '1';
        wait until falling_edge(clk);
        start <= '0';
        assert unsigned(block_value(31 downto 0)) = expected and
               block_value(127 downto 32) = iv and active = '1' and overflow = '0'
            report "ICB_START_CONTRACT" severity failure;
        while count < budget loop
            wait until rising_edge(clk);
            count := count + 1;
            expected_overflow := '0';
            if expected = unsigned'(x"ffffffff") then
                expected_overflow := '1';
            else
                expected := expected + 1;
            end if;
            wait for 1 ns;
            observed := overflow;
            if negative and count = 8 then
                report "INJECTION_REACHED ICB_EARLY_OVERFLOW";
                observed := '1';
            end if;
            assert observed = expected_overflow
                report "ICB_OVERFLOW_EDGE" severity failure;
            assert unsigned(block_value(31 downto 0)) = expected and
                   block_value(127 downto 32) = iv and active = not expected_overflow
                report "ICB_COUNTER_OR_ACTIVE" severity failure;
            if expected_overflow = '1' then
                report "ICB_ENTITY_OVERFLOW_REACHED edge=" & to_hstring(count);
                finish;
            end if;
            if count(23 downto 0) = 0 then
                report "ICB_PROGRESS edge=" & to_hstring(count);
            end if;
        end loop;
        report "ICB_NOT_REACHED edge=" & to_hstring(count);
        finish;
    end process;
end architecture;
