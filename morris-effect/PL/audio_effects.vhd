library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.aud_param.all;

-- Audio Effects Pipeline
-- Modular architecture for chaining multiple audio effects
-- Currently implements: Gain control
-- Future effects can be easily added by inserting modules in the chain
--
-- Effects Chain Flow:
--   Input → Gain Effect → [Future Effect 1] → [Future Effect 2] → Output
--
-- To add a new effect:
--   1. Create new effect module (e.g., echo_effect.vhd)
--   2. Add component declaration in params.vhd
--   3. Instantiate in this file between existing effects
--   4. Add control registers in ctrl_bus.vhd if needed

entity audio_effects is
    generic (
        DATA_WIDTH : natural := 32;
        PCM_PRECISION : natural := 18;
        GAIN_WIDTH : natural := 32
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;

        -- Input audio stream from FIFO
        audio_in    : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_in    : in  std_logic;

        -- Control signals from AXI4-Lite registers
        gain_reg    : in  std_logic_vector(GAIN_WIDTH - 1 downto 0);
        -- Add more control registers here for future effects:
        -- eq_reg      : in  std_logic_vector(31 downto 0);
        -- reverb_reg  : in  std_logic_vector(31 downto 0);

        -- Output audio stream to AXI4-Stream
        audio_out   : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_out   : out std_logic
    );
end audio_effects;

architecture Behavioral of audio_effects is
    -- Signals for effect chain
    -- Naming convention: effect_name_out, effect_name_valid

    -- After gain effect
    signal gain_out : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal gain_valid : std_logic;

    -- Add more intermediate signals here for future effects:
    -- signal eq_out : std_logic_vector(DATA_WIDTH - 1 downto 0);
    -- signal eq_valid : std_logic;
    -- signal reverb_out : std_logic_vector(DATA_WIDTH - 1 downto 0);
    -- signal reverb_valid : std_logic;

begin

    -- Effect 1: Gain Control
    gain_effect_inst : gain_effect
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

    -- Effect 2: [Future Effect - Placeholder]
    -- Example: EQ or Filter
    -- eq_effect_inst : eq_effect
    --     generic map (
    --         DATA_WIDTH => DATA_WIDTH
    --     )
    --     port map (
    --         clk => clk,
    --         rst => rst,
    --         audio_in => gain_out,        -- Chain from previous effect
    --         valid_in => gain_valid,
    --         eq_coeff => eq_reg,
    --         audio_out => eq_out,
    --         valid_out => eq_valid
    --     );

    -- Effect 3: [Future Effect - Placeholder]
    -- Example: Reverb or Echo
    -- reverb_effect_inst : reverb_effect
    --     generic map (
    --         DATA_WIDTH => DATA_WIDTH
    --     )
    --     port map (
    --         clk => clk,
    --         rst => rst,
    --         audio_in => eq_out,          -- Chain from previous effect
    --         valid_in => eq_valid,
    --         reverb_time => reverb_reg,
    --         audio_out => reverb_out,
    --         valid_out => reverb_valid
    --     );

    -- Final output assignment
    -- Update this when adding new effects to chain from the last effect
    audio_out <= gain_out;
    valid_out <= gain_valid;

    -- When adding effects, update to:
    -- audio_out <= reverb_out;
    -- valid_out <= reverb_valid;

end Behavioral;
