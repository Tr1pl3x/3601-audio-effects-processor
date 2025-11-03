library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fifo is
    generic (
        DATA_WIDTH : positive := 32;
        FIFO_DEPTH : positive := 5
    );
    port (
        clkw    : in  std_logic;
        clkr    : in  std_logic;
        rst     : in  std_logic;
        wr      : in  std_logic;
        rd      : in  std_logic;
        din     : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        empty   : out std_logic;
        full    : out std_logic;
        dout    : out std_logic_vector(DATA_WIDTH-1 downto 0)
    );
end fifo;

architecture arch of fifo is
    type fifo_t is array (0 to 2**FIFO_DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal mem : fifo_t;

    signal rdp, wrp : unsigned(FIFO_DEPTH downto 0) := (others => '0');
    signal int_rdp : unsigned(FIFO_DEPTH-1 downto 0);
    signal int_wrp : unsigned(FIFO_DEPTH-1 downto 0);

    signal sig_full : std_logic;
    signal sig_empty : std_logic;
    
    signal data_out_reg : std_logic_vector(DATA_WIDTH-1 downto 0);

begin

    --you need to implement the rest of this file
    --hint:
    -- handle write operations on the rising edge of the write clock, remember to increment write pointer
    -- handle read operations on the rising edge of the read clock, remember to increment read pointer
    -- status signal and empty signal can be computed asynchronously against the read/write pointer values
    -- remember to deal with reset signal
    -- output value can be computed asynchronously using the read pointer
    
    -- Pointer conversion for memory addressing
    int_rdp <= rdp(FIFO_DEPTH-1 downto 0);
    int_wrp <= wrp(FIFO_DEPTH-1 downto 0);

    -- Write process (synchronous to write clock)
    process(clkw, rst)
    begin
        if rst = '1' then
            wrp <= (others => '0');
        elsif rising_edge(clkw) then
            if wr = '1' and sig_full = '0' then
                mem(to_integer(int_wrp)) <= din;
                wrp <= wrp + 1;
            end if;
        end if;
    end process;

    -- Read process (synchronous to read clock)
    process(clkr, rst)
    begin
        if rst = '1' then
            rdp <= (others => '0');
            data_out_reg <= (others => '0');
        elsif rising_edge(clkr) then
            if rd = '1' and sig_empty = '0' then
                data_out_reg <= mem(to_integer(int_rdp));
                rdp <= rdp + 1;
            end if;
        end if;
    end process;

    -- Full and empty flags (asynchronous)
    sig_full <= '1' when (wrp(FIFO_DEPTH) /= rdp(FIFO_DEPTH)) and 
                         (wrp(FIFO_DEPTH-1 downto 0) = rdp(FIFO_DEPTH-1 downto 0)) 
                else '0';
                
    sig_empty <= '1' when rdp = wrp else '0';

    -- Output assignments
    full <= sig_full;
    empty <= sig_empty;
    dout <= data_out_reg;

    
end arch;
