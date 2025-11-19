library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.aud_param.all;

entity audio_pipeline is
    generic(
        PCM_PRECISION : integer := 18;
        PCM_WIDTH : integer := 24;
        DATA_WIDTH : integer := 32;
        FIFO_DEPTH : integer := 12;
        TRANSFER_LEN : integer := 5;
		C_S00_AXI_DATA_WIDTH    : integer	:= 32;
		C_S00_AXI_ADDR_WIDTH	: integer	:= 5
    );
    port(
        clk: in std_logic;
        rst: in std_logic;

        --------------------------------------------------
        -- I2S INPUT (from microphone)
        --------------------------------------------------
        i2s_bclk_in     : out std_logic;
        i2s_lrcl_in     : out std_logic;
        i2s_dout        : in  std_logic;

        --------------------------------------------------
        -- I2S OUTPUT (to speaker)
        --------------------------------------------------
        i2s_bclk_out    : out std_logic;
        i2s_lrcl_out    : out std_logic;
        i2s_din         : out std_logic;

        --------------------------------------------------
        -- AXI4-Stream (to DMA for SD card)
        --------------------------------------------------
        axis_tdata      : out std_logic_vector(DATA_WIDTH-1 downto 0);
        axis_tvalid     : out std_logic;
        axis_tready     : in  std_logic;
        axis_tlast      : out std_logic;
        
        --------------------------------------------------
        -- Control interface (AXI4-Lite)
        --------------------------------------------------
		s00_axi_aclk	: in  std_logic;
		s00_axi_aresetn	: in  std_logic;
		s00_axi_awaddr	: in  std_logic_vector(C_S00_AXI_ADDR_WIDTH-1 downto 0);
		s00_axi_awprot	: in  std_logic_vector(2 downto 0);
		s00_axi_awvalid	: in  std_logic;
		s00_axi_awready	: out std_logic;
		s00_axi_wdata	: in  std_logic_vector(C_S00_AXI_DATA_WIDTH-1 downto 0);
		s00_axi_wstrb	: in  std_logic_vector((C_S00_AXI_DATA_WIDTH/8)-1 downto 0);
		s00_axi_wvalid	: in  std_logic;
		s00_axi_wready	: out std_logic;
		s00_axi_bresp	: out std_logic_vector(1 downto 0);
		s00_axi_bvalid	: out std_logic;
		s00_axi_bready	: in  std_logic;
		s00_axi_araddr	: in  std_logic_vector(C_S00_AXI_ADDR_WIDTH-1 downto 0);
		s00_axi_arprot	: in  std_logic_vector(2 downto 0);
		s00_axi_arvalid	: in  std_logic;
		s00_axi_arready	: out std_logic;
		s00_axi_rdata	: out std_logic_vector(C_S00_AXI_DATA_WIDTH-1 downto 0);
		s00_axi_rresp	: out std_logic_vector(1 downto 0);
		s00_axi_rvalid	: out std_logic;
		s00_axi_rready	: in  std_logic
    );
end audio_pipeline;

architecture Behavioural of audio_pipeline is
    --------------------------------------------------
    -- FIFO
    --------------------------------------------------
    signal sig_fifo_rst             : std_logic;
    signal sig_fifo_wr              : std_logic;
    signal sig_fifo_rd              : std_logic;
    signal sig_fifo_full            : std_logic;
    signal sig_fifo_empty           : std_logic;
    signal sig_fifo_data_w          : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal sig_fifo_data_r          : std_logic_vector(DATA_WIDTH-1 downto 0);

    --------------------------------------------------
    -- AXI4-Stream
    --------------------------------------------------
    signal sig_axis_tdata           : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal sig_axis_tvalid          : std_logic;
    signal sig_axis_tready          : std_logic;
    signal sig_axis_tlast           : std_logic;

    --------------------------------------------------
    -- Control interface (AXI4-Lite)
    --------------------------------------------------
    signal sig_control_reg          : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal sig_status_reg           : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal sig_gain_reg             : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal sig_speed_reg             : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal sig_effect_sel           : std_logic_vector(2 downto 0);
    -- Echo effect control signals
    signal sig_echo_delay           : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal sig_echo_feedback        : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal sig_echo_mix             : std_logic_vector(DATA_WIDTH-1 downto 0);

    --------------------------------------------------
    -- Audio Effects
    --------------------------------------------------
    signal sig_effects_in           : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal sig_effects_in_valid     : std_logic;
    signal sig_effects_out          : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal sig_effects_out_valid    : std_logic;

    --------------------------------------------------
    -- Speaker output
    --------------------------------------------------
    signal sig_speaker_ready        : std_logic;

begin

    sig_status_reg <= x"0ca7cafe";
    
    --------------------------------------------------
    -- Control bus
    --------------------------------------------------
    inst_ctrl_bus : entity work.ctrl_bus
	generic map (
		C_S_AXI_DATA_WIDTH	=> C_S00_AXI_DATA_WIDTH,
		C_S_AXI_ADDR_WIDTH	=> C_S00_AXI_ADDR_WIDTH
	)
	port map (
        cb_control_reg  => sig_control_reg,
        cb_status_reg   => sig_status_reg,
        cb_gain_reg     => sig_gain_reg,
        cb_speed_reg    => sig_speed_reg,
        cb_effect_sel   => sig_effect_sel,
        cb_echo_delay   => sig_echo_delay,
        cb_echo_feedback => sig_echo_feedback,
        cb_echo_mix     => sig_echo_mix,

		S_AXI_ACLK	    => s00_axi_aclk,
		S_AXI_ARESETN	=> s00_axi_aresetn,
		S_AXI_AWADDR	=> s00_axi_awaddr,
		S_AXI_AWPROT	=> s00_axi_awprot,
		S_AXI_AWVALID	=> s00_axi_awvalid,
		S_AXI_AWREADY	=> s00_axi_awready,
		S_AXI_WDATA	    => s00_axi_wdata,
		S_AXI_WSTRB	    => s00_axi_wstrb,
		S_AXI_WVALID	=> s00_axi_wvalid,
		S_AXI_WREADY	=> s00_axi_wready,
		S_AXI_BRESP	    => s00_axi_bresp,
		S_AXI_BVALID	=> s00_axi_bvalid,
		S_AXI_BREADY	=> s00_axi_bready,
		S_AXI_ARADDR	=> s00_axi_araddr,
		S_AXI_ARPROT	=> s00_axi_arprot,
		S_AXI_ARVALID	=> s00_axi_arvalid,
		S_AXI_ARREADY	=> s00_axi_arready,
		S_AXI_RDATA	    => s00_axi_rdata,
		S_AXI_RRESP	    => s00_axi_rresp,
		S_AXI_RVALID	=> s00_axi_rvalid,
		S_AXI_RREADY	=> s00_axi_rready
	);

    sig_fifo_rst <= '0';

    --------------------------------------------------
    -- I2S Master (now with both RX and TX)
    --------------------------------------------------
    inst_i2s_master : i2s_master
    generic map (
        DATA_WIDTH      => DATA_WIDTH,
        PCM_PRECISION   => PCM_PRECISION
    )
    port map (
        clk             => clk,
        rst             => sig_fifo_rst,

        -- I2S input from microphone
        i2s_lrcl_in     => i2s_lrcl_in,
        i2s_dout        => i2s_dout,
        i2s_bclk_in     => i2s_bclk_in,

        -- I2S output to speaker
        i2s_lrcl_out    => i2s_lrcl_out,
        i2s_din         => i2s_din,
        i2s_bclk_out    => i2s_bclk_out,

        -- FIFO interface from microphone
        fifo_din        => sig_fifo_data_w,
        fifo_w_stb      => sig_fifo_wr,
        fifo_full       => sig_fifo_full,

        -- Speaker output data
        speaker_data    => sig_effects_out,      -- Send processed audio to speaker
        speaker_valid   => sig_effects_out_valid,
        speaker_ready   => sig_speaker_ready
    );

    --------------------------------------------------
    -- FIFO
    --------------------------------------------------
    inst_fifo : fifo 
    generic map (
        data_width => DATA_WIDTH,
        fifo_depth => FIFO_DEPTH
    ) port map (
        clkw            => clk,
        clkr            => clk,
        rst             => sig_fifo_rst,

        wr              => sig_fifo_wr,
        din             => sig_fifo_data_w,
        full            => sig_fifo_full,

        rd              => sig_fifo_rd,
        dout            => sig_fifo_data_r,
        empty           => sig_fifo_empty
    );

    --------------------------------------------------
    -- Audio Effects Pipeline
    --------------------------------------------------
    -- FIFO read control: read when not empty and effects are ready
    sig_fifo_rd <= (not sig_fifo_empty) and sig_speaker_ready;

    -- Connect FIFO output to effects input
    sig_effects_in <= sig_fifo_data_r;
    sig_effects_in_valid <= sig_fifo_rd;

    inst_audio_effects : entity work.audio_effects
    generic map (
        DATA_WIDTH => DATA_WIDTH,
        PCM_PRECISION => PCM_PRECISION,
        GAIN_WIDTH => DATA_WIDTH
    )
    port map (
        clk => clk,
        rst => sig_fifo_rst,
        audio_in => sig_effects_in,
        valid_in => sig_effects_in_valid,
        effect_selector => sig_effect_sel,
        gain_reg => sig_gain_reg,
        speed_reg => sig_speed_reg,
        echo_delay_reg => sig_echo_delay,
        echo_feedback_reg => sig_echo_feedback,
        echo_mix_reg => sig_echo_mix,
        audio_out => sig_effects_out,
        valid_out => sig_effects_out_valid
    );

    --------------------------------------------------
    -- Effects to AXIS (for SD card recording)
    --------------------------------------------------
    -- AXIS valid comes from effects pipeline output
    sig_axis_tvalid <= sig_effects_out_valid;
    axis_tvalid <= sig_axis_tvalid;
    
    -- TLAST generation (every 1024 samples)
    process (clk)
        variable v_cnt : integer := 0;
    begin
        if (sig_fifo_rst = '1') then
            v_cnt := 0;
        elsif rising_edge(clk) then
            if ((sig_axis_tvalid and axis_tready) = '1') then
                v_cnt := v_cnt + 1;
                
                if (v_cnt = 1024) then
                    axis_tlast <= '1';
                    v_cnt := 0;
                else
                    axis_tlast <= '0';
                end if;
            end if;
        end if;
    end process;

    -- TDATA from effects pipeline output
    axis_tdata <= sig_effects_out;

end Behavioural;

