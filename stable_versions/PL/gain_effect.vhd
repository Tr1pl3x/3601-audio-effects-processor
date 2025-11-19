library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Gain effect module for audio processing
-- Uses Q16.16 fixed-point arithmetic for precise gain control
-- Gain range: 0.0x to 2.0x
-- Format: 16 integer bits + 16 fractional bits
-- Examples:
--   0x00000000 = 0.0x (mute)
--   0x00008000 = 0.5x (half volume)
--   0x00010000 = 1.0x (unity/bypass)
--   0x00018000 = 1.5x (boost)
--   0x00020000 = 2.0x (max boost)

entity gain_effect is
    generic (
        DATA_WIDTH : natural := 32;
        PCM_PRECISION : natural := 18;
        GAIN_WIDTH : natural := 32  -- Q16.16 format
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;

        -- Input audio stream
        audio_in    : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_in    : in  std_logic;

        -- Gain control (Q16.16 fixed-point)
        gain_coeff  : in  std_logic_vector(GAIN_WIDTH - 1 downto 0);

        -- Output audio stream
        audio_out   : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_out   : out std_logic
    );
end gain_effect;

architecture Behavioral of gain_effect is
    -- Internal signals for pipeline
    signal audio_in_signed : signed(DATA_WIDTH - 1 downto 0);
    signal gain_signed : signed(GAIN_WIDTH - 1 downto 0);
    signal mult_result : signed(DATA_WIDTH + GAIN_WIDTH - 1 downto 0);  -- 64-bit intermediate
    signal mult_result_reg : signed(DATA_WIDTH + GAIN_WIDTH - 1 downto 0);  -- Registered for saturation
    signal scaled_result : signed(DATA_WIDTH - 1 downto 0);
    signal saturated_result : signed(DATA_WIDTH - 1 downto 0);

    -- Pipeline registers for timing
    signal valid_stage1 : std_logic := '0';
    signal valid_stage2 : std_logic := '0';
    signal valid_stage3 : std_logic := '0';

    -- Saturation constants (32-bit signed range)
    constant MAX_POSITIVE : signed(DATA_WIDTH - 1 downto 0) := to_signed(2147483647, DATA_WIDTH);  -- 2^31 - 1
    constant MAX_NEGATIVE : signed(DATA_WIDTH - 1 downto 0) := to_signed(-2147483648, DATA_WIDTH); -- -2^31

begin
    -- Convert inputs to signed
    audio_in_signed <= signed(audio_in);
    gain_signed <= signed(gain_coeff);

    -- Pipeline Stage 1: Multiplication
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                mult_result <= (others => '0');
                valid_stage1 <= '0';
            else
                if valid_in = '1' then
                    -- Multiply: 32-bit audio × 32-bit gain = 64-bit result
                    mult_result <= audio_in_signed * gain_signed;
                end if;
                valid_stage1 <= valid_in;
            end if;
        end if;
    end process;

    -- Pipeline Stage 2: Register multiplication result and scale
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                mult_result_reg <= (others => '0');
                scaled_result <= (others => '0');
                valid_stage2 <= '0';
            else
                -- Register the multiplication result
                mult_result_reg <= mult_result;

                if valid_stage1 = '1' then
                    -- Shift right by 16 bits to convert from Q16.16 back to integer
                    -- This is equivalent to dividing by 65536
                    scaled_result <= mult_result(47 downto 16);  -- Take bits [47:16]
                end if;
                valid_stage2 <= valid_stage1;
            end if;
        end if;
    end process;

    -- Pipeline Stage 3: Saturation logic (prevent overflow/underflow)
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                saturated_result <= (others => '0');
                valid_stage3 <= '0';
            else
                -- Check if the upper bits indicate overflow
                -- For a 64-bit result, bits [63:47] should all match bit [47] (sign extension)
                -- If they don't match, we have overflow
                if mult_result_reg(63 downto 47) /= (mult_result_reg(63 downto 47)'range => mult_result_reg(47)) then
                    -- Overflow detected
                    if mult_result_reg(63) = '1' then
                        -- Negative overflow
                        saturated_result <= MAX_NEGATIVE;
                    else
                        -- Positive overflow
                        saturated_result <= MAX_POSITIVE;
                    end if;
                else
                    -- No overflow, use scaled result
                    saturated_result <= scaled_result;
                end if;

                valid_stage3 <= valid_stage2;
            end if;
        end if;
    end process;

    -- Output assignment
    audio_out <= std_logic_vector(saturated_result);
    valid_out <= valid_stage3;

end Behavioral;
