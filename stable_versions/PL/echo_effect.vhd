----------------------------------------------------------------------------------
-- Company: UNSW
-- Engineer: 
--
-- Create Date: 11/11/2025
-- Module Name: echo_effect - Behavioral
-- Project Name: Audio Effects System
-- Description: Simple echo effect with adjustable delay, feedback, and wet/dry mix
--              Uses circular buffer (BRAM) for delay line storage
--              3-stage pipeline to match gain_effect timing
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity echo_effect is
    generic (
        DATA_WIDTH : natural := 32;
        PCM_PRECISION : natural := 18;
        MAX_DELAY_SAMPLES : natural := 12000  -- 250ms at 48kHz
    );
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;
        audio_in      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_in      : in  std_logic;
        delay_reg     : in  std_logic_vector(31 downto 0);  -- Delay in samples (0 to MAX_DELAY_SAMPLES)
        feedback_reg  : in  std_logic_vector(31 downto 0);  -- Feedback gain (Q16.16 format, 0.0 to 0.9)
        mix_reg       : in  std_logic_vector(31 downto 0);  -- Wet/dry mix (Q16.16 format, 0.0 to 1.0)
        audio_out     : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_out     : out std_logic
    );
end echo_effect;

architecture Behavioral of echo_effect is

    -- Delay line memory (circular buffer using BRAM)
    type delay_memory_t is array (0 to MAX_DELAY_SAMPLES - 1) of signed(DATA_WIDTH - 1 downto 0);
    signal delay_buffer : delay_memory_t := (others => (others => '0'));

    -- Pointer management
    signal write_ptr : unsigned(15 downto 0) := (others => '0');  -- Current sample position
    signal read_ptr  : unsigned(15 downto 0) := (others => '0');  -- Delayed sample position

    -- Stage 1 signals (Read from delay buffer and compute feedback)
    signal stage1_valid       : std_logic := '0';
    signal stage1_audio_in    : signed(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal stage1_delayed     : signed(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal stage1_delay_amt   : unsigned(15 downto 0) := (others => '0');
    signal stage1_feedback    : signed(31 downto 0) := (others => '0');
    signal stage1_mix         : signed(31 downto 0) := (others => '0');

    -- Stage 2 signals (Apply feedback and compute wet signal)
    signal stage2_valid       : std_logic := '0';
    signal stage2_audio_in    : signed(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal stage2_delayed     : signed(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal stage2_feedback_mult : signed(63 downto 0) := (others => '0');
    signal stage2_wet         : signed(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal stage2_mix         : signed(31 downto 0) := (others => '0');

    -- Stage 3 signals (Mix dry and wet signals)
    signal stage3_valid       : std_logic := '0';
    signal stage3_audio_in    : signed(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal stage3_wet         : signed(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal stage3_dry_mult    : signed(63 downto 0) := (others => '0');
    signal stage3_wet_mult    : signed(63 downto 0) := (others => '0');
    signal stage3_mixed       : signed(DATA_WIDTH - 1 downto 0) := (others => '0');

begin

    ----------------------------------------------------------------------------------
    -- Stage 1: Read from delay buffer and capture control registers
    ----------------------------------------------------------------------------------
    process(clk)
        variable delay_amount : unsigned(15 downto 0);
        variable read_address : unsigned(15 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                stage1_valid <= '0';
                stage1_audio_in <= (others => '0');
                stage1_delayed <= (others => '0');
                stage1_delay_amt <= (others => '0');
                stage1_feedback <= (others => '0');
                stage1_mix <= (others => '0');
                read_ptr <= (others => '0');
            elsif valid_in = '1' then
                -- Capture input and control values
                stage1_valid <= '1';
                stage1_audio_in <= signed(audio_in);
                stage1_feedback <= signed(feedback_reg);
                stage1_mix <= signed(mix_reg);

                -- Calculate delay amount (clamp to MAX_DELAY_SAMPLES)
                if unsigned(delay_reg) > MAX_DELAY_SAMPLES then
                    delay_amount := to_unsigned(MAX_DELAY_SAMPLES, 16);
                else
                    delay_amount := unsigned(delay_reg(15 downto 0));
                end if;
                stage1_delay_amt <= delay_amount;

                -- Calculate read pointer (write_ptr - delay_amount) with wraparound
                if write_ptr >= delay_amount then
                    read_address := write_ptr - delay_amount;
                else
                    read_address := to_unsigned(MAX_DELAY_SAMPLES, 16) + write_ptr - delay_amount;
                end if;
                read_ptr <= read_address;

                -- Read delayed sample from buffer
                stage1_delayed <= delay_buffer(to_integer(read_address));
            else
                stage1_valid <= '0';
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------------
    -- Stage 2: Apply feedback and create wet signal, write to delay buffer
    ----------------------------------------------------------------------------------
    process(clk)
        variable feedback_scaled : signed(DATA_WIDTH - 1 downto 0);
        variable wet_signal : signed(DATA_WIDTH - 1 downto 0);
        variable temp_sum : signed(DATA_WIDTH downto 0);  -- Extra bit for overflow detection
    begin
        if rising_edge(clk) then
            if rst = '1' then
                stage2_valid <= '0';
                stage2_audio_in <= (others => '0');
                stage2_delayed <= (others => '0');
                stage2_feedback_mult <= (others => '0');
                stage2_wet <= (others => '0');
                stage2_mix <= (others => '0');
                write_ptr <= (others => '0');
            elsif stage1_valid = '1' then
                stage2_valid <= '1';
                stage2_audio_in <= stage1_audio_in;
                stage2_mix <= stage1_mix;

                -- Multiply delayed signal by feedback gain (Q16.16 format)
                stage2_feedback_mult <= stage1_delayed * stage1_feedback;

                -- Scale back from Q32.32 to Q16.16 (shift right by 16 bits)
                feedback_scaled := resize(stage2_feedback_mult(47 downto 16), DATA_WIDTH);

                -- Check for saturation in feedback multiplication
                if stage2_feedback_mult(63 downto 47) /= (stage2_feedback_mult'high downto 47 => stage2_feedback_mult(47)) then
                    -- Overflow detected, saturate
                    if stage2_feedback_mult(63) = '1' then
                        feedback_scaled := to_signed(-2147483648, DATA_WIDTH);  -- Most negative
                    else
                        feedback_scaled := to_signed(2147483647, DATA_WIDTH);   -- Most positive
                    end if;
                end if;

                -- Create wet signal: input + (delayed * feedback)
                temp_sum := resize(stage1_audio_in, DATA_WIDTH + 1) + resize(feedback_scaled, DATA_WIDTH + 1);

                -- Saturate the sum
                if temp_sum > 2147483647 then
                    wet_signal := to_signed(2147483647, DATA_WIDTH);
                elsif temp_sum < -2147483648 then
                    wet_signal := to_signed(-2147483648, DATA_WIDTH);
                else
                    wet_signal := resize(temp_sum, DATA_WIDTH);
                end if;

                stage2_wet <= wet_signal;
                stage2_delayed <= stage1_delayed;

                -- Write wet signal (with feedback) to delay buffer
                delay_buffer(to_integer(write_ptr)) <= wet_signal;

                -- Increment write pointer with wraparound
                if write_ptr >= MAX_DELAY_SAMPLES - 1 then
                    write_ptr <= (others => '0');
                else
                    write_ptr <= write_ptr + 1;
                end if;
            else
                stage2_valid <= '0';
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------------
    -- Stage 3: Mix dry and wet signals based on mix_reg
    ----------------------------------------------------------------------------------
    process(clk)
        variable dry_scaled : signed(DATA_WIDTH - 1 downto 0);
        variable wet_scaled : signed(DATA_WIDTH - 1 downto 0);
        variable one_minus_mix : signed(31 downto 0);
        variable mixed_sum : signed(DATA_WIDTH downto 0);  -- Extra bit for overflow
    begin
        if rising_edge(clk) then
            if rst = '1' then
                stage3_valid <= '0';
                stage3_audio_in <= (others => '0');
                stage3_wet <= (others => '0');
                stage3_dry_mult <= (others => '0');
                stage3_wet_mult <= (others => '0');
                stage3_mixed <= (others => '0');
                audio_out <= (others => '0');
                valid_out <= '0';
            elsif stage2_valid = '1' then
                stage3_valid <= '1';
                stage3_audio_in <= stage2_audio_in;
                stage3_wet <= stage2_wet;

                -- Calculate (1.0 - mix) for dry signal scaling (Q16.16 format: 1.0 = 0x00010000)
                one_minus_mix := to_signed(65536, 32) - stage2_mix;

                -- Multiply dry signal by (1 - mix)
                stage3_dry_mult <= stage2_audio_in * one_minus_mix;

                -- Multiply wet signal by mix
                stage3_wet_mult <= stage2_wet * stage2_mix;

                -- Scale and saturate dry component
                dry_scaled := resize(stage3_dry_mult(47 downto 16), DATA_WIDTH);
                if stage3_dry_mult(63 downto 47) /= (stage3_dry_mult'high downto 47 => stage3_dry_mult(47)) then
                    if stage3_dry_mult(63) = '1' then
                        dry_scaled := to_signed(-2147483648, DATA_WIDTH);
                    else
                        dry_scaled := to_signed(2147483647, DATA_WIDTH);
                    end if;
                end if;

                -- Scale and saturate wet component
                wet_scaled := resize(stage3_wet_mult(47 downto 16), DATA_WIDTH);
                if stage3_wet_mult(63 downto 47) /= (stage3_wet_mult'high downto 47 => stage3_wet_mult(47)) then
                    if stage3_wet_mult(63) = '1' then
                        wet_scaled := to_signed(-2147483648, DATA_WIDTH);
                    else
                        wet_scaled := to_signed(2147483647, DATA_WIDTH);
                    end if;
                end if;

                -- Sum dry and wet components
                mixed_sum := resize(dry_scaled, DATA_WIDTH + 1) + resize(wet_scaled, DATA_WIDTH + 1);

                -- Final saturation
                if mixed_sum > 2147483647 then
                    stage3_mixed <= to_signed(2147483647, DATA_WIDTH);
                elsif mixed_sum < -2147483648 then
                    stage3_mixed <= to_signed(-2147483648, DATA_WIDTH);
                else
                    stage3_mixed <= resize(mixed_sum, DATA_WIDTH);
                end if;

                -- Output the mixed result
                audio_out <= std_logic_vector(stage3_mixed);
                valid_out <= '1';
            else
                valid_out <= '0';
            end if;
        end if;
    end process;

end Behavioral;
