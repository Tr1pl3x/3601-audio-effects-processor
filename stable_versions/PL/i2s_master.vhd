library ieee;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;

library work;
use work.aud_param.all;

-- Enhanced I2S master with both receiver (from mic) and transmitter (to speaker)
entity i2s_master is
    generic (
        DATA_WIDTH : natural := 32;
        PCM_PRECISION : natural := 18
    );
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- I2S interface to MEMs mic (INPUT)
        i2s_lrcl_in     : out std_logic;
        i2s_dout        : in  std_logic;
        i2s_bclk_in     : out std_logic;

        -- I2S interface to speaker (OUTPUT)  
        i2s_lrcl_out    : out std_logic;
        i2s_din         : out std_logic;
        i2s_bclk_out    : out std_logic;

        -- FIFO interface from MEMs mic
        fifo_din        : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        fifo_w_stb      : out std_logic;
        fifo_full       : in  std_logic;

        -- Audio data for speaker output
        speaker_data    : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        speaker_valid   : in  std_logic;
        speaker_ready   : out std_logic
    );
end i2s_master;

architecture Behavioral of i2s_master is
    -- I2S clock generation constants
    constant BCLK_DIVIDER : integer := 16; -- System clock to bit clock divider
    constant LRCLK_DIVIDER : integer := 64; -- Bit clock to word clock divider
    
    -- I2S clock signals
    signal bclk_counter : unsigned(7 downto 0) := (others => '0');
    signal lrclk_counter : unsigned(7 downto 0) := (others => '0');
    signal bclk_int : std_logic := '0';
    signal lrclk_int : std_logic := '0';
    
    -- Receiver signals
    signal bit_counter_rx : unsigned(5 downto 0) := (others => '0');
    signal shift_reg_rx : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal data_reg_rx : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal sample_ready_rx : std_logic := '0';
    type state_type_rx is (IDLE_RX, SHIFTING_RX, STORE_RX);
    signal state_rx : state_type_rx := IDLE_RX;

    -- Transmitter signals
    signal bit_counter_tx : unsigned(5 downto 0) := (others => '0');
    signal shift_reg_tx : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal data_reg_tx : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal tx_data_ready : std_logic := '0';
    signal tx_active : std_logic := '0';
    type state_type_tx is (IDLE_TX, LOAD_TX, SHIFTING_TX);
    signal state_tx : state_type_tx := IDLE_TX;

begin

    -- Shared I2S clock generation
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                bclk_counter <= (others => '0');
                lrclk_counter <= (others => '0');
                bclk_int <= '0';
                lrclk_int <= '0';
            else
                -- Generate bit clock
                if bclk_counter = BCLK_DIVIDER - 1 then
                    bclk_counter <= (others => '0');
                    bclk_int <= not bclk_int;
                else
                    bclk_counter <= bclk_counter + 1;
                end if;

                -- Generate word clock (LRCLK) on falling edge of BCLK
                if bclk_int = '1' and bclk_counter = 0 then
                    if lrclk_counter = LRCLK_DIVIDER - 1 then
                        lrclk_counter <= (others => '0');
                        lrclk_int <= not lrclk_int;
                    else
                        lrclk_counter <= lrclk_counter + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Connect clocks to both input and output
    i2s_bclk_in <= bclk_int;
    i2s_bclk_out <= bclk_int;
    i2s_lrcl_in <= lrclk_int;
    i2s_lrcl_out <= lrclk_int;

    ----------------------------------------------------------------------------
    -- I2S RECEIVER (from microphone)
    ----------------------------------------------------------------------------
    receiver_fsm : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state_rx <= IDLE_RX;
                sample_ready_rx <= '0';
                bit_counter_rx <= (others => '0');
                shift_reg_rx <= (others => '0');
                data_reg_rx <= (others => '0');
            else
                case state_rx is
                    when IDLE_RX =>
                        sample_ready_rx <= '0';
                        if (lrclk_int = '0') and bclk_int = '1' and bclk_counter = 0 then
                            state_rx <= SHIFTING_RX;
                            bit_counter_rx <= (others => '0');
                            shift_reg_rx <= (others => '0');
                        end if;
                        
                    when SHIFTING_RX =>
                        if bclk_int = '1' and bclk_counter = 0 then
                            -- Shift in data on rising edge of BCLK
                            shift_reg_rx <= shift_reg_rx(DATA_WIDTH - 2 downto 0) & i2s_dout;
                            bit_counter_rx <= bit_counter_rx + 1;
                            
                            if bit_counter_rx = DATA_WIDTH - 1 then
                                state_rx <= STORE_RX;
                            end if;
                        end if;
                        
                    when STORE_RX =>
                        data_reg_rx <= shift_reg_rx;
                        sample_ready_rx <= '1';
                        state_rx <= IDLE_RX;
                        
                    when others =>
                        state_rx <= IDLE_RX;
                end case;
            end if;
        end if;
    end process;

    -- FIFO write handshake for received data
    fifo_write_process : process(clk)
    begin
        if rising_edge(clk) then
            fifo_w_stb <= '0';
            
            if sample_ready_rx = '1' and fifo_full = '0' then
                fifo_din <= data_reg_rx;
                fifo_w_stb <= '1';
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- I2S TRANSMITTER (to speaker)
    ----------------------------------------------------------------------------
    transmitter_fsm : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state_tx <= IDLE_TX;
                i2s_din <= '0';
                shift_reg_tx <= (others => '0');
                data_reg_tx <= (others => '0');
                tx_data_ready <= '0';
                tx_active <= '0';
                bit_counter_tx <= (others => '0');
            else
                case state_tx is
                    when IDLE_TX =>
                        i2s_din <= '0';
                        tx_data_ready <= '1'; -- Ready for new data
                        
                        if speaker_valid = '1' and tx_data_ready = '1' then
                            data_reg_tx <= speaker_data;
                            tx_data_ready <= '0';
                            state_tx <= LOAD_TX;
                        end if;
                        
                    when LOAD_TX =>
                        -- Wait for start of frame (LRCLK falling edge)
                        if lrclk_int = '0' and bclk_int = '1' and bclk_counter = 0 then
                            shift_reg_tx <= data_reg_tx;
                            bit_counter_tx <= (others => '0');
                            tx_active <= '1';
                            state_tx <= SHIFTING_TX;
                        end if;
                        
                    when SHIFTING_TX =>
                        if bclk_int = '0' and bclk_counter = BCLK_DIVIDER/2 then
                            -- Shift out data on falling edge of BCLK
                            i2s_din <= shift_reg_tx(DATA_WIDTH - 1);
                            shift_reg_tx <= shift_reg_tx(DATA_WIDTH - 2 downto 0) & '0';
                            bit_counter_tx <= bit_counter_tx + 1;
                            
                            if bit_counter_tx = DATA_WIDTH - 1 then
                                tx_active <= '0';
                                state_tx <= IDLE_TX;
                            end if;
                        end if;
                        
                    when others =>
                        state_tx <= IDLE_TX;
                end case;
            end if;
        end if;
    end process;

    speaker_ready <= tx_data_ready;

end Behavioral;