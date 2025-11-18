library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity clipper_effect is
    generic (
        DATA_WIDTH     : natural := 32;
        PCM_PRECISION  : natural := 18
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;

        audio_in    : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_in    : in  std_logic;

        audio_out   : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_out   : out std_logic
    );
end clipper_effect;

architecture Behavioral of clipper_effect is
    signal sample_in : signed(DATA_WIDTH - 1 downto 0);

    signal stage1, stage2, stage3, stage4 : signed(DATA_WIDTH - 1 downto 0);
    signal v1, v2, v3, v4                 : std_logic;

    constant EXTRA_BITS : integer := DATA_WIDTH - PCM_PRECISION;

    constant CLIP_POS : signed(DATA_WIDTH - 1 downto 0) :=
        shift_left(
            to_signed(2**(PCM_PRECISION - 1) - 1, DATA_WIDTH),
            EXTRA_BITS
        );

    constant CLIP_NEG : signed(DATA_WIDTH - 1 downto 0) :=
        shift_left(
            to_signed(-(2**(PCM_PRECISION - 1)), DATA_WIDTH),
            EXTRA_BITS
        );

    signal clipped_sample : signed(DATA_WIDTH - 1 downto 0);

begin
    sample_in <= signed(audio_in);

    clipped_sample <=
        (others => '0') when sample_in > CLIP_POS else
        (others => '0') when sample_in < CLIP_NEG else
        sample_in;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                stage1 <= (others => '0');
                stage2 <= (others => '0');
                stage3 <= (others => '0');
                stage4 <= (others => '0');
                v1     <= '0';
                v2     <= '0';
                v3     <= '0';
                v4     <= '0';
            else
                -- stage1：
                if valid_in = '1' then
                    stage1 <= clipped_sample;
                end if;
                v1 <= valid_in;

                -- stage2：extend 
                stage2 <= stage1;
                v2     <= v1;

                -- stage3：extend 
                stage3 <= stage2;
                v3     <= v2;

                -- stage4：extend 
                stage4 <= stage3;
                v4     <= v3;
            end if;
        end if;
    end process;

    audio_out <= std_logic_vector(stage4);
    valid_out <= v4;
end Behavioral;