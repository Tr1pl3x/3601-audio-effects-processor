library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.aud_param.all;

-- Audio Effects Pipeline with MUX Selection
-- Architecture: All effects run in parallel, MUX selects which one to output
-- Currently implements: Bypass (None) and Gain control
-- Other effects: Echo, Speed up/down, Clipping, Flanger (to be added by teammates)
--
-- Effects Selection Flow:
--   Input → [Bypass | Echo | Gain | Speed | Clipping | Flanger] → MUX → Output
--                                                                    ↑
--                                                              effect_selector
--
-- Effect Selector Values (3-bit):
--   0: None (Bypass - audio passes through unchanged)
--   1: Echo
--   2: Gain
--   3: Speed up/Slow down
--   4: Clipping
--   5: Flanger
--
-- To add a new effect:
--   1. Create effect module (e.g., echo_effect.vhd)
--   2. Add component declaration in params.vhd
--   3. Instantiate in this file
--   4. Connect to MUX in process

entity audio_effects is
    generic (
        DATA_WIDTH : natural := 32;
        PCM_PRECISION : natural := 18;
        GAIN_WIDTH  : natural := 32;
        SPEED_WIDTH : natural := 32
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;

        -- Input audio stream from FIFO
        audio_in    : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_in    : in  std_logic;

        -- Effect selector (from PS via AXI4-Lite)
        -- 000: None/Bypass, 001: Echo, 010: Gain, 011: Speed, 100: Clipping, 101: Flanger
        effect_selector : in  std_logic_vector(2 downto 0);

        -- Control registers for each effect
        gain_reg    : in  std_logic_vector(GAIN_WIDTH - 1 downto 0);
        -- Future effect control registers:
        -- echo_reg    : in  std_logic_vector(31 downto 0);
        speed_reg   : in  std_logic_vector(SPEED_WIDTH - 1 downto 0);
        -- clip_reg    : in  std_logic_vector(31 downto 0);
        -- flanger_reg : in  std_logic_vector(31 downto 0);

        -- Output audio stream to AXI4-Stream
        audio_out   : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_out   : out std_logic
    );
end audio_effects;

architecture Behavioral of audio_effects is
    -- Signals for parallel effects outputs
    -- Each effect runs in parallel, MUX selects which one to use

    -- Bypass (None) - just delay to match other effects' latency
    signal bypass_out : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal bypass_valid : std_logic;
    signal bypass_stage1, bypass_stage2, bypass_stage3, bypass_stage4 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal bypass_valid_stage1, bypass_valid_stage2, bypass_valid_stage3, bypass_valid_stage4 : std_logic;
    signal gain_bypass, gain_bypass_st4 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal gain_valid_bypass, gain_valid_bypass_st4 : std_logic;
    signal speed_mode       : std_logic_vector(1 downto 0);
    signal speed_bypass_st2, speed_bypass_st3, speed_bypass_st4, speed_bypass      : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal speed_valid_bypass_st2, speed_valid_bypass_st3, speed_valid_bypass_st4, speed_valid_bypass : std_logic;
    
    
    -- Echo effect output
    signal echo_out : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal echo_valid : std_logic;

    -- Gain effect output
    signal gain_out : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal gain_valid : std_logic;

    -- Speed up/down effect output
    signal speed_out : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal speed_valid : std_logic;

    -- Clipping effect output
    signal clipping_out : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal clipping_valid : std_logic;

    -- Flanger effect output
    signal flanger_out : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal flanger_valid : std_logic;
    
    --first sample
    signal first_sample : std_logic := '1';

begin

    ----------------------------------------------------------------------------
    -- Bypass Path (None) - 3-stage pipeline to match gain effect latency
    ----------------------------------------------------------------------------
    bypass_pipeline : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                bypass_stage1 <= (others => '0');
                bypass_stage2 <= (others => '0');
                bypass_stage3 <= (others => '0');
                bypass_stage4 <= (others => '0');
                bypass_valid_stage1 <= '0';
                bypass_valid_stage2 <= '0';
                bypass_valid_stage3 <= '0';
                bypass_valid_stage4 <= '0';
            else            
                -- Stage 1
                bypass_stage1 <= audio_in;
                bypass_valid_stage1 <= valid_in;

                -- Stage 2
                bypass_stage2 <= bypass_stage1;
                bypass_valid_stage2 <= bypass_valid_stage1;
                --speed bypass stage 2
                speed_bypass_st2 <= speed_out;
                speed_valid_bypass_st2 <= speed_valid;

                -- Stage 3
                bypass_stage3 <= bypass_stage2;
                bypass_valid_stage3 <= bypass_valid_stage2;
                --speed bypass stage 3
                speed_bypass_st3 <= speed_bypass_st2;
                speed_valid_bypass_st3 <= speed_valid_bypass_st2;
                
                --Stage 4
                bypass_valid_stage4 <= bypass_valid_stage3;
                bypass_stage4 <= bypass_stage3;
                --gain bypass from stage 3 to stage 4
                gain_valid_bypass_st4 <= gain_valid;
                gain_bypass_st4 <= gain_out;
                --speed bypass stage 3
                speed_bypass_st4 <= speed_bypass_st3;
                speed_valid_bypass_st4 <= speed_valid_bypass_st3;
                
            end if;
        end if;
    end process;

    --bypass outputs
    gain_bypass <= gain_bypass_st4;
    gain_valid_bypass <= gain_valid_bypass_st4;
    bypass_out <= bypass_stage4;
    bypass_valid <= bypass_valid_stage4;
    speed_bypass <= speed_bypass_st4;
    speed_valid_bypass <= speed_valid_bypass_st4;  

    ----------------------------------------------------------------------------
    -- Effect 1: Echo (Placeholder - pass-through for now)
    -- TODO: Morris will implement echo_effect.vhd
    ----------------------------------------------------------------------------
    echo_out <= bypass_stage4; --audio_in;  -- Placeholder - just pass through
    echo_valid <= bypass_valid_stage4;

    ----------------------------------------------------------------------------
    -- Effect 2: Gain Control (Already implemented) (3 clock cycles)
    ----------------------------------------------------------------------------
    gain_effect_inst : entity work.gain_effect
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            PCM_PRECISION => PCM_PRECISION,
            GAIN_WIDTH => GAIN_WIDTH
        )
        port map (
            clk => clk,
            rst => rst,
            audio_in => audio_in,
            valid_in => valid_in,
            gain_coeff => gain_reg,
            audio_out => gain_out,
            valid_out => gain_valid
        );

    ----------------------------------------------------------------------------
    -- Effect 3: Speed up/Slow down (3 clock cycles)
    ----------------------------------------------------------------------------
    speed_effect_inst : entity work.speed_effect
        generic map (DATA_WIDTH => DATA_WIDTH)
        port map (
            clk => clk, rst => rst,
            audio_in => audio_in, valid_in => valid_in,
            speed_mode => speed_reg(1 downto 0),
            audio_out => speed_out, valid_out => speed_valid
        );


    ----------------------------------------------------------------------------
    -- Effect 4: Clipping (Placeholder - pass-through for now)
    -- TODO: Ayush will implement clipping_effect.vhd
    ----------------------------------------------------------------------------
    clipping_out <= audio_in;  -- Placeholder - just pass through
    clipping_valid <= valid_in;

    ----------------------------------------------------------------------------
    -- Effect 5: Flanger (4 clock cycles)
    ----------------------------------------------------------------------------
    flanger_effect_inst : entity work.flanger
    port map (
            clk => clk,
            rst => rst,
            data_in => audio_in,
            data_in_ready => valid_in,
            data_out_ready => flanger_valid,
            data_out => flanger_out);

    ----------------------------------------------------------------------------
    -- Output MUX: Select which effect to use based on effect_selector
    ----------------------------------------------------------------------------
    effect_mux : process(effect_selector, bypass_out, bypass_valid,
                         echo_out, echo_valid, gain_out, gain_valid,
                         speed_out, speed_valid, clipping_out, clipping_valid,
                         flanger_out, flanger_valid)
    begin
        case effect_selector is
            when "000" =>  -- None/Bypass
                audio_out <= bypass_out;
                valid_out <= bypass_valid;

            when "001" =>  -- Echo
                audio_out <= echo_out;
                valid_out <= echo_valid;

            when "010" =>  -- Gain
                audio_out <= gain_bypass;
                valid_out <= gain_valid_bypass;

            when "011" =>  -- Speed up/Slow down
                audio_out <= speed_bypass;
                valid_out <= speed_valid_bypass;

            when "100" =>  -- Clipping
                audio_out <= clipping_out;
                valid_out <= clipping_valid;

            when "101" =>  -- Flanger
                audio_out <= flanger_out;
                valid_out <= flanger_valid;

            when others =>  -- Default to bypass
                audio_out <= bypass_out;
                valid_out <= bypass_valid;
        end case;
    end process;

end Behavioral;
