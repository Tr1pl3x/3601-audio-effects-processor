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
    signal sample_in   : signed(DATA_WIDTH - 1 downto 0);
    signal sample_out  : signed(DATA_WIDTH - 1 downto 0);

    signal valid_reg   : std_logic := '0';

    constant EXTRA_BITS : integer := DATA_WIDTH - PCM_PRECISION;

    -- positive upper limit： (2^(PCM_PRECISION-1) - 1) << EXTRA_BITS
    -- negative lower limit：-(2^(PCM_PRECISION-1)     ) << EXTRA_BITS
    constant CLIP_POS : signed(DATA_WIDTH - 1 downto 0) :=
        shift_left( 
            to_signed(2**(PCM_PRECISION - 1) - 1, DATA_WIDTH) ,
            EXTRA_BITS
        );

    constant CLIP_NEG : signed(DATA_WIDTH - 1 downto 0) :=
        shift_left( 
            to_signed(-(2**(PCM_PRECISION - 1)), DATA_WIDTH) ,
            EXTRA_BITS
        );
begin
    sample_in <= signed(audio_in);

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                sample_out <= (others => '0');
                valid_reg  <= '0';
            else
                valid_reg <= '0';

                if valid_in = '1' then
                    -- Hard cut: If the value is outside the range, 
                    --  it will get stuck at CLIP_POS/CLIP_NEG.
                    if sample_in > CLIP_POS then
                        sample_out <= CLIP_POS;
                    elsif sample_in < CLIP_NEG then
                        sample_out <= CLIP_NEG;
                    else
                        sample_out <= sample_in;
                    end if;

                    valid_reg <= '1';
                end if;
            end if;
        end if;
    end process;

    audio_out <= std_logic_vector(sample_out);
    valid_out <= valid_reg;
end Behavioral;
