library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity speed_effect is
    generic (
        DATA_WIDTH : natural := 32
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;

        audio_in    : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        valid_in    : in  std_logic;

        -- control: 0=normal(1x), 1=speed x2, 2=slow x0.5 (linear interp)
        speed_mode  : in  std_logic_vector(1 downto 0);

        audio_out   : out std_logic_vector(DATA_WIDTH-1 downto 0);
        valid_out   : out std_logic
    );
end speed_effect;

architecture Behavioral of speed_effect is
    signal in_s      : signed(DATA_WIDTH-1 downto 0);
    signal prev_s    : signed(DATA_WIDTH-1 downto 0) := (others => '0');
    signal curr_s    : signed(DATA_WIDTH-1 downto 0) := (others => '0');

    -- for x2 (decimate by 2)
    signal keep_next : std_logic := '0';  -- toggle: output on '1'

    -- for x0.5 (insert mid sample)
    signal have_prev : std_logic := '0';
    signal pending_mid : std_logic := '0';
    signal mid_s     : signed(DATA_WIDTH-1 downto 0);

    signal out_s     : signed(DATA_WIDTH-1 downto 0);
    signal out_v     : std_logic := '0';
begin
    in_s <= signed(audio_in);

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                prev_s      <= (others => '0');
                curr_s      <= (others => '0');
                keep_next   <= '0';
                have_prev   <= '0';
                pending_mid <= '0';
                out_s       <= (others => '0');
                out_v       <= '0';
            else
                out_v <= '0';

                case speed_mode is
                    -- 00: normal 1x (pass-through)
                    when "00" =>
                        if valid_in = '1' then
                            out_s <= in_s;
                            out_v <= '1';
                            prev_s <= in_s;
                            have_prev <= '1';
                        end if;

                    -- 01: speed x2 (drop every other sample)
                    when "01" =>
                        if valid_in = '1' then
                            -- toggle and only output on keep_next='1'
                            keep_next <= not keep_next;
                            if keep_next = '1' then
                                out_s <= in_s;
                                out_v <= '1';
                            end if;
                            prev_s <= in_s;
                            have_prev <= '1';
                        end if;

                    -- 10: slow x0.5 (linear interpolation)
                    when "10" =>
                        if pending_mid = '1' then
                            -- second cycle: output interpolated mid
                            out_s <= mid_s;
                            out_v <= '1';
                            pending_mid <= '0';
                        elsif valid_in = '1' then
                            -- got a new sample
                            curr_s <= in_s;
                            if have_prev = '1' then
                                -- 1st output: previous sample
                                out_s <= prev_s;
                                out_v <= '1';
                                -- prepare mid = (prev + curr)/2
                                mid_s <= resize( shift_right(prev_s + in_s, 1), DATA_WIDTH );
                                pending_mid <= '1';
                            else
                                -- no previous yet -> just latch, no output this cycle
                                have_prev <= '1';
                            end if;
                            prev_s <= in_s;
                        end if;

                    when others =>
                        -- default to pass-through
                        if valid_in = '1' then
                            out_s <= in_s;
                            out_v <= '1';
                            prev_s <= in_s;
                            have_prev <= '1';
                        end if;
                end case;
            end if;
        end if;
    end process;

    audio_out <= std_logic_vector(out_s);
    valid_out <= out_v;
end Behavioral;
