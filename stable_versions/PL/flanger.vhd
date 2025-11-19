----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 10/28/2025 11:18:27 AM
-- Design Name: 
-- Module Name: flanger - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity flanger is
  generic (
        DATA_WIDTH : positive := 32;
        PCM_PRECISION : integer := 18
    );
  Port (
    signal clk      : in std_logic;
    signal rst      : in std_logic;
    signal data_in  : in std_logic_vector(DATA_WIDTH - 1 DOWNTO 0);
    signal data_out : out std_logic_vector(DATA_WIDTH - 1 DOWNTO 0);
    signal data_in_ready : in std_logic;  --1 clk signal to indicate new input is ready
    signal data_out_ready : out std_logic --1 clk signal to indicate new output is ready
    --signal fifo_full      : in std_logic
  );
end flanger;
architecture Behavioral of flanger is
    --effect of flanger (g)
    signal g_shift: integer := 2; --g = 0.5 (shift the sample by 2)
    
    --LFO wave, LFO delay is between 1ms and 10ms a.k.a. 48 to 480 samples
    constant BASE_DELAY : integer := 48;
    constant MIN_DELAY : integer := 48;
    constant BUF_SIZE  : integer := 528;
    constant MAX_DELAY : integer := 480;
    constant LFO_HALF_PERIOD : integer := 9999936; --generate triangular LFO: 100 MHZ -> 5Hz: 1000000 * 100 / 5 / 2 --10000000
    constant CLK_PER_STEP : integer := 23148;
    signal clk_count      : integer range 0 to LFO_HALF_PERIOD := 0;
    --signal clk_step_count : integer range 0 to CLK_PER_STEP - 1 := 0;
    signal current_delay : integer range MIN_DELAY to MAX_DELAY := MIN_DELAY;
    signal lfo_dir        : std_logic := '0'; --0 = up, 1 = down
    signal all_clk_count  : integer := 0;
    signal clk_count_per_step : integer range 0 to CLK_PER_STEP := 0;
    
    --let max delay be 10 ms, base delay = min delay be 1ms
    type sample_array_t is array (0 to BUF_SIZE - 1) of std_logic_vector(DATA_WIDTH-1 downto 0); --480 samples = 10 ms, shift array
    signal previous_samples : sample_array_t := (others => (others => '0'));
    signal samples_ptr, delayed_index      : integer range 0 to BUF_SIZE - 1 := 0;
    
    --for arithmetics on the output of interpolation
    signal delayed_sample_18 : signed(17 downto 0);
    signal delayed_sample_scaled : signed(17 downto 0);
    signal delayed_sample_ext : signed(31 downto 0);
    signal zeros_14 : signed(13 downto 0) := (others => '0');
    
    --for interpolation
    constant INTERPOL_MULTIPLY          : integer := 46385; --(2^30) / 23148 (16 bits) (46385 if round up)
    constant INTERPOL_SHIFT_DIVIDE      : integer := 1073741824; --DIVIDE BY 2^30
   
    --pipeline registers
    --stage 1
    signal stage1_input                : std_logic_vector(31 downto 0);
    signal new_sample_st1              : std_logic;
    signal delayed_sample0_18bit, delayed_sample1_18bit       : signed(17 downto 0);
    signal clk_count_per_step_st1      : integer range 0 to CLK_PER_STEP := 0;
    
    --stage 2
    signal d_sample0_mult, d_sample1_mult   : signed(34 downto 0);
    signal new_sample_st2              : std_logic;
    signal stage2_input                : std_logic_vector(31 downto 0);
    signal clk_count_per_step_st2      : integer range 0 to CLK_PER_STEP := 0;
    
    --stage 3
    signal d_sample0_mult2, d_sample1_mult2 : signed(50 downto 0);
    signal stage3_input                : std_logic_vector(31 downto 0);
    signal new_sample_st3              : std_logic;
    
begin
    --PIPELINE STAGE 1--
    --PIPELINED REGISTERS STAGE 1
    process(clk) 
        variable d_index0, d_index1 : integer range 0 to BUF_SIZE - 1;
    begin
        if (rising_edge(clk)) then
            --save current input
            stage1_input <= data_in;
            new_sample_st1 <= data_in_ready;
            --indexes for samples
            d_index0 := (samples_ptr - BASE_DELAY - current_delay + BUF_SIZE - 1) mod BUF_SIZE;
            d_index1 := (samples_ptr - BASE_DELAY - current_delay + BUF_SIZE) mod BUF_SIZE;           
            --extract previous samples that we will use in later stages
            delayed_sample0_18bit <= signed(previous_samples(d_index0)(31 downto 14));
            delayed_sample1_18bit <= signed(previous_samples(d_index1)(31 downto 14));
            --clk count for cauclations
            clk_count_per_step_st1 <= clk_count_per_step;
        end if;
    end process;
    
    --UPDATE BUFFER
    process(clk) begin
        --rising clock
        if (rising_edge(clk)) then
            --reset
            if(rst = '1') then
               previous_samples <= (others => (others => '0'));
               samples_ptr <= 0;
            --no reset
            else
                --if there is a new sample
                if (data_in_ready = '1') then
                    --if the buffer is full
                    if (samples_ptr = BUF_SIZE - 1) then
                        samples_ptr <= 0; --samples_ptr;
                        previous_samples(samples_ptr) <= data_in;
                    --if the buffer is not full
                    else
                        samples_ptr <= samples_ptr + 1;
                        previous_samples(samples_ptr) <= data_in;
                    end if;
                --if there is no new sample
                else
                    samples_ptr <= samples_ptr;
                end if;
            end if;
        end if;
    end process;
    
    
    --generate LFO
    --TODO
    process(clk, rst) begin
        if (rst = '1') then
            clk_count_per_step <= 0;
            clk_count <= 0;
        elsif(rising_edge(clk)) then
            --clk count per step
            if (clk_count_per_step < CLK_PER_STEP) THEN
                clk_count_per_step <= clk_count_per_step + 1;
            else
                clk_count_per_step <= 0;
            end if;
        
            if (lfo_dir = '0') then            
                if (clk_count < LFO_HALF_PERIOD) then --was < LFO_HALF_PERIOD
                clk_count <= clk_count + 1;
                else
                    clk_count <= clk_count;
                    lfo_dir <= '1';
                end if;
            else
                if (clk_count > 0) then
                    clk_count <= clk_count - 1;
                else
                    clk_count <= clk_count;
                    lfo_dir <= '0';
                end if;
            end if;
        end if;
    end process;
    
    --generate current delay based on LFO
    --TODO
    process(clk, rst) begin
        if (rst = '1') then
            current_delay <= 48;
        elsif(rising_edge(clk)) then
            if ((clk_count_per_step = CLK_PER_STEP)) then
                if (lfo_dir = '0') then
                    if (current_delay < 480) then
                        current_delay <= current_delay + 1;
                    else
                        current_delay <= MAX_DELAY;
                    end if;
                else
                    if (current_delay > 48) then
                        current_delay <= current_delay - 1;
                    else
                        current_delay <= MIN_DELAY;
                    end if;
                end if;
            else
                current_delay <= current_delay;
            end if;
        end if;
    end process;
    
    --calculate output
    
    --STAGE 2 (multiply by 2^30)
    process(clk) begin
        if (rising_edge(clk)) then
            d_sample0_mult <= delayed_sample0_18bit * to_signed(INTERPOL_MULTIPLY, 17);
            d_sample1_mult <= delayed_sample1_18bit * to_signed(INTERPOL_MULTIPLY, 17);
            new_sample_st2 <= new_sample_st1;
            stage2_input <= stage1_input;
            clk_count_per_step_st2 <= clk_count_per_step_st1;
        end if;
    end process;
    
    --STAGE 3 (multiply by top of the fraction)
    process(clk) begin
        if (rising_edge(clk)) then
            d_sample0_mult2 <= d_sample0_mult * (to_signed(CLK_PER_STEP, 16) - to_signed(clk_count_per_step_st2, 16)); --16 * 35
            d_sample1_mult2 <= d_sample1_mult * to_signed(clk_count_per_step_st2, 16);
            new_sample_st3 <= new_sample_st2;
            stage3_input <= stage2_input;
        end if;
    end process;
    
    --STAGE 4
    process(clk) 
        variable d_sample_scaled : signed(17 downto 0);
        variable d_sample_ext    : signed(31 downto 0);
        variable d_sample0_div, d_sample1_div, d_samples_sum : signed(17 downto 0);
    begin
        if(rising_edge(clk)) then
            --simply divide by 2^30, very fast shift
            d_sample0_div := resize(shift_right(d_sample0_mult2, 30), 18); --resize(d_sample0_mult2 / to_signed(INTERPOL_SHIFT_DIVIDE, 31), 18); --was 31 bit
            d_sample1_div := resize(shift_right(d_sample1_mult2, 30), 18); --resize(d_sample1_mult2 / to_signed(INTERPOL_SHIFT_DIVIDE, 31), 18);
            --add
            d_samples_sum := d_sample0_div + d_sample1_div;
            --divide by 2
            d_sample_scaled := d_samples_sum / 2;
            d_sample_ext := d_sample_scaled & zeros_14;
            
            --return output
            if ((new_sample_st3 = '1')) then
                data_out_ready <= '1';
            else
                data_out_ready <= '0';
            end if;
            
            if (new_sample_st3 = '1') then
                 data_out <= std_logic_vector(signed(stage3_input) + d_sample_ext);
            end if;
        end if;
    end process;
end Behavioral;