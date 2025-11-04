library ieee;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;

library work;
use work.aud_param.all;

-- I2S master interface for the SPH0645LM4H MEMs mic
-- Links:
--   - https://diyi0t.com/i2s-sound-tutorial-for-esp32/
--   - https://cdn-learn.adafruit.com/downloads/pdf/adafruit-i2s-mems-microphone-breakout.pdf
--   - https://cdn-shop.adafruit.com/product-files/3421/i2S+Datasheet.PDF

entity i2s_master is
    generic (
        DATA_WIDTH : natural := 32;
        PCM_PRECISION : natural := 18
    );
    port (
        clk             : in  std_logic;

        -- I2S interface to MEMs mic
        i2s_lrcl        : out std_logic;    -- left/right clk (word sel): 0 = left, 1 = right
        i2s_dout        : in  std_logic;    -- serial data: payload, msb first
        i2s_bclk        : out std_logic;    -- Bit clock: freq = sample rate * bits per channel * number of channels
                                            -- (should run at 2-4MHz). Changes when the next bit is ready.
        -- FIFO interface to MEMs mic
        fifo_din        : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        fifo_w_stb      : out std_logic;    -- Write strobe: 1 = ready to write, 0 = busy
        fifo_full       : in  std_logic     -- 1 = not full, 0 = full
    );
end i2s_master;

architecture Behavioral of i2s_master is
    constant BCLK_DIVIDER : integer := 16; -- System clock to bit clock divider --was 4
    constant LRCLK_DIVIDER : integer := 64; -- Bit clock to word clock divider --was 64
    
    signal bclk_counter : unsigned(7 downto 0) := (others => '0');
    signal lrclk_counter : unsigned(7 downto 0) := (others => '0');
    signal bit_counter : unsigned(5 downto 0) := (others => '0');
    
    signal bclk_int : std_logic := '0';
    signal lrclk_int : std_logic := '0';
    
    signal shift_reg : std_logic_vector(DATA_WIDTH - 1 downto 0); -- serial to parallel
    signal data_reg : std_logic_vector(DATA_WIDTH - 1 downto 0); -- save parallel 
    
    signal sample_ready : std_logic := '0';
    
    type state_type is (IDLE, SHIFTING, STORE); -- FSM
    signal state : state_type := IDLE;

begin

    -- Bit Clock (BCLK) Generator
    process(clk)
    begin
        if rising_edge(clk) then
            if bclk_counter = BCLK_DIVIDER - 1 then
                bclk_counter <= (others => '0');
                bclk_int <= not bclk_int;
            else
                bclk_counter <= bclk_counter + 1;
            end if;
        end if;
    end process;

    -- LR Clock (Word Select) Generator  
    process(clk)
    begin
        if rising_edge(clk) then
            if bclk_int = '1' and bclk_counter = 0 then
                if lrclk_counter = LRCLK_DIVIDER - 1 then
                    lrclk_counter <= (others => '0');
                    lrclk_int <= not lrclk_int;
                else
                    lrclk_counter <= lrclk_counter + 1;
                end if;
            end if;
        end if;
    end process;
    -- I2S FSM for data shifting and capturing
    process(clk)
    begin
        if rising_edge(clk) then
            case state is
                when IDLE =>
                    sample_ready <= '0';
                    if (lrclk_int = '0') and bclk_int = '1' and bclk_counter = 0 then
                        state <= SHIFTING;
                        bit_counter <= (others => '0');
                        shift_reg <= (others => '0');
                    end if;
                    
                when SHIFTING =>
                    if bclk_int = '1' and bclk_counter = 0 then
                        -- Shift in data on rising edge of BCLK
                        shift_reg <= shift_reg(DATA_WIDTH - 2 downto 0) & i2s_dout;
                        bit_counter <= bit_counter + 1;
                        
                        if bit_counter = DATA_WIDTH - 1 then
                            state <= STORE;
                        end if;
                    end if;
                    
                when STORE =>
                    data_reg <= shift_reg;
                    sample_ready <= '1';
                    state <= IDLE;
                    
                when others =>
                    state <= IDLE;
            end case;
        end if;
    end process;

    -- FIFO Data Handshake
    process(clk)
    begin
        if rising_edge(clk) then
            fifo_w_stb <= '0';
            
            if sample_ready = '1' and fifo_full = '0' then
                fifo_din <= data_reg;
                fifo_w_stb <= '1';
            end if;
        end if;
    end process;

    -- Output assignments
    i2s_bclk <= bclk_int;
    i2s_lrcl <= lrclk_int;


end Behavioral;