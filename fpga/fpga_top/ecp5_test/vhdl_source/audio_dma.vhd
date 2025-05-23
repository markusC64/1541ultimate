library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.io_bus_pkg.all;
use work.mem_bus_pkg.all;

entity audio_dma is
generic (
    g_tag       : std_logic_vector(7 downto 0) := X"BA"
);
port (
    audio_clock : in  std_logic;
    audio_reset : in  std_logic;
    audio_pulse : in  std_logic;
    left_out    : out std_logic_vector(23 downto 0);
    right_out   : out std_logic_vector(23 downto 0);
    left_in     : in  std_logic_vector(23 downto 0);
    right_in    : in  std_logic_vector(23 downto 0);

    sys_clock   : in  std_logic;
    sys_reset   : in  std_logic;
    misc_io     : out std_logic_vector(7 downto 0);
    io_req      : in  t_io_req;
    io_resp     : out t_io_resp;
    mem_req     : out t_mem_req_32 := c_mem_req_32_init;
    mem_resp    : in  t_mem_resp_32 );
end entity;

architecture gideon of audio_dma is
    type t_state is (idle, do_access, read2, read3, read4, write2, write3);
    signal state        : t_state;

    signal sys_in_reset     : std_logic;
    signal sys_in_valid     : std_logic;
    signal sys_in_ready     : std_logic;
    signal sys_in_data      : std_logic_vector(47 downto 0);
    signal sys_out_valid    : std_logic;
    signal sys_out_full     : std_logic;
    signal sys_out_ready    : std_logic;
    signal sys_out_data     : std_logic_vector(47 downto 0);

    signal misc_io_i        : std_logic_vector(7 downto 0);

    signal in_toggle        : std_logic := '0';
    signal in_enable        : std_logic := '0';
    signal in_continuous    : std_logic := '0';
    signal in_address       : unsigned(mem_req.address'range);
    signal in_start         : unsigned(mem_req.address'range);
    signal in_end           : unsigned(mem_req.address'range);
    signal in_mode          : std_logic_vector(1 downto 0);
    alias  a_in_mode_16bit  : std_logic is in_mode(0);
    alias  a_in_mode_mono   : std_logic is in_mode(1);

    signal out_toggle       : std_logic := '0';
    signal out_enable       : std_logic := '0';
    signal out_continuous   : std_logic := '0';
    signal out_address      : unsigned(mem_req.address'range);
    signal out_start        : unsigned(mem_req.address'range);
    signal out_end          : unsigned(mem_req.address'range);
    signal out_mode         : std_logic_vector(1 downto 0);
    alias  a_out_mode_16bit : std_logic is out_mode(0);
    alias  a_out_mode_mono  : std_logic is out_mode(1);
begin
    -- Synchronize samples with sys clock domain
    i_out: entity work.async_fifo_ft
        generic map (
            g_fast       => false,
            g_data_width => 48,
            g_depth_bits => 8
        )
        port map (
            wr_clock => sys_clock,
            wr_reset => sys_reset,
            wr_en    => sys_out_valid,
            wr_din   => sys_out_data,
            wr_full  => sys_out_full,

            rd_clock => audio_clock,
            rd_reset => audio_reset,
            rd_next  => audio_pulse,
            rd_dout(47 downto 24) => left_out,
            rd_dout(23 downto 00) => right_out,
            rd_valid => open,
            rd_count => open
        );
    sys_out_ready <= not sys_out_full;
    
    i_in: entity work.async_fifo_ft
        generic map (
            g_fast       => false,
            g_data_width => 48,
            g_depth_bits => 8
        )
        port map (
            wr_clock => audio_clock,
            wr_reset => audio_reset,
            wr_en    => audio_pulse,
            wr_din(47 downto 24) => left_in,
            wr_din(23 downto 00) => right_in,
            wr_full  => open,

            rd_clock => sys_clock,
            rd_reset => sys_in_reset,
            rd_next  => sys_in_ready,
            rd_dout  => sys_in_data,
            rd_valid => sys_in_valid,
            rd_count => open
        );
        
    sys_in_reset <= sys_reset or not in_enable;

    process(sys_clock)
        variable v_addr : natural range 0 to 31;
    begin
        if rising_edge(sys_clock) then
            sys_out_valid <= '0';
            sys_in_ready <= '0';
            mem_req.tag <= g_tag;
            case state is
            when idle =>
                mem_req.request <= '0';
                if in_address >= in_end and in_enable = '1' then
                    if in_continuous = '1' then
                        in_address <= in_start;
                    else
                        in_enable <= '0';
                    end if;
                end if;
                if out_address >= out_end and out_enable = '1' then
                    if out_continuous = '1' then
                        out_address <= out_start;
                    else
                        out_enable <= '0';
                    end if;
                end if;
                state <= do_access;

            when do_access =>
                if in_enable = '1' and sys_in_valid = '1' then
                    mem_req.address <= in_address;
                    mem_req.read_writen <= '0';
                    mem_req.request <= '1';
                    if a_in_mode_16bit = '1' then
                        sys_in_ready <= '1'; -- always possible to store entire sample, whether it is mono or not
                        state <= write3;
                        if a_in_mode_mono = '0' then -- if it is stereo, we store both left and right
                            mem_req.data <= sys_in_data(47 downto 32) & sys_in_data(23 downto 8);
                            mem_req.byte_en <= "1111";
                            in_toggle <= '0';
                            in_address <= in_address + 4;
                        elsif in_toggle = '0' then -- mono 16 bit, store either in lower or upper half of the word
                            mem_req.data <= X"0000" & sys_in_data(47 downto 32);
                            mem_req.byte_en <= "0011";
                            in_toggle <= '1';
                        else
                            mem_req.data <= sys_in_data(47 downto 32) & X"0000";
                            mem_req.byte_en <= "1100";
                            in_toggle <= '0';
                            in_address <= in_address + 4;
                        end if;
                    else -- 32 bit, we might need two writes, first write left
                        mem_req.data <= sys_in_data(47 downto 24) & X"00";
                        mem_req.byte_en <= "1111";
                        in_address <= in_address + 4;
                        if a_in_mode_mono = '1' then
                            sys_in_ready <= '1';  -- just one sample, we consumed it
                            state <= write3;
                        else
                            state <= write2; -- extra write needed
                        end if;
                    end if;

                elsif out_enable = '1' and sys_out_ready = '1' then
                    mem_req.data <= (others => 'X');
                    mem_req.address <= out_address;
                    mem_req.read_writen <= '1';
                    mem_req.request <= '1';
                    state <= read2;
                else
                    state <= idle;
                end if;
            
            when write2 => -- write other channel
                if mem_resp.rack = '1' and mem_resp.rack_tag = g_tag then -- write request accepted
                    sys_in_ready <= '1'; -- sample consumed
                    mem_req.request <= '1'; -- still 1
                    mem_req.read_writen <= '0';
                    mem_req.address <= in_address;
                    mem_req.data    <= sys_in_data(23 downto 0) & X"00";
                    mem_req.byte_en <= "1111";
                    in_address <= in_address + 4;
                    state <= write3;
                end if;

            when write3 =>
                if mem_resp.rack = '1' and mem_resp.rack_tag = g_tag then -- write request accepted
                    mem_req.request <= '0';
                    state <= idle;
                end if;

            when read2 =>
                if mem_resp.rack = '1' and mem_resp.rack_tag = g_tag then -- read request accepted -- turn off req
                    mem_req.request <= '0';
                end if;
                if mem_resp.dack_tag = g_tag then
                    if a_out_mode_16bit = '1' then
                        if a_out_mode_mono = '0' then -- both left and right
                            sys_out_data <= mem_resp.data(31 downto 16) & X"00" & mem_resp.data(15 downto 0) & X"00";
                            out_address <= out_address + 4;
                            sys_out_valid <= '1';
                            out_toggle <= '0';
                            state <= idle;
                        elsif out_toggle = '0' then -- mono
                            out_toggle <= '1';
                            sys_out_data <= mem_resp.data(15 downto 0) & X"00" & mem_resp.data(15 downto 0) & X"00";
                            sys_out_valid <= '1';
                            state <= idle;
                        else -- mono, second sample
                            out_address <= out_address + 4;
                            out_toggle <= '0';
                            sys_out_data <= mem_resp.data(31 downto 16) & X"00" & mem_resp.data(31 downto 16) & X"00";
                            sys_out_valid <= '1';
                            state <= idle;
                        end if;
                    else -- 32 bit audio
                        sys_out_data <= mem_resp.data(31 downto 8) & mem_resp.data(31 downto 8);
                        out_address <= out_address + 4;
                        if a_out_mode_mono = '1' then
                            sys_out_valid <= '1';
                            state <= idle;
                        else -- expecting second sample
                            state <= read3;
                        end if;
                    end if;
                end if;
            
            when read3 =>
                out_address <= out_address + 4;
                mem_req.address <= out_address;
                mem_req.read_writen <= '1';
                mem_req.request <= '1';
                state <= read4;

            when read4 => -- 32 bit second read for right sample only
                if mem_resp.rack = '1' and mem_resp.rack_tag = g_tag then -- read request accepted -- turn off req
                    mem_req.request <= '0';
                end if;
                if mem_resp.dack_tag = g_tag then
                    sys_out_data(23 downto 00) <= mem_resp.data(31 downto 8);
                    sys_out_valid <= '1';
                    state <= idle;
                end if;

            when others =>
                null;
            end case;

            io_resp <= c_io_resp_init;

            v_addr := to_integer(io_req.address(4 downto 0));
            if io_req.read='1' then
                io_resp.ack <= '1';
                case v_addr is
                when 0 =>
                    io_resp.data <= std_logic_vector(in_address(7 downto 0));
                when 1 =>
                    io_resp.data <= std_logic_vector(in_address(15 downto 8));
                when 2 =>
                    io_resp.data <= std_logic_vector(in_address(23 downto 16));
                when 3 =>
                    io_resp.data(in_address'high - 24 downto 0) <= std_logic_vector(in_address(in_address'high downto 24));
                when 4 =>
                    io_resp.data <= std_logic_vector(in_end(7 downto 0));
                when 5 =>
                    io_resp.data <= std_logic_vector(in_end(15 downto 8));
                when 6 =>
                    io_resp.data <= std_logic_vector(in_end(23 downto 16));
                when 7 =>
                    io_resp.data(in_end'high - 24 downto 0) <= std_logic_vector(in_end(in_end'high downto 24));
                when 8 =>
                    io_resp.data(0) <= in_enable;
                    io_resp.data(1) <= in_continuous;
                when 9 =>
                    io_resp.data(1 downto 0) <= in_mode;
                when 16 =>
                    io_resp.data <= std_logic_vector(out_address(7 downto 0));
                when 17 =>
                    io_resp.data <= std_logic_vector(out_address(15 downto 8));
                when 18 =>
                    io_resp.data <= std_logic_vector(out_address(23 downto 16));
                when 19 =>
                    io_resp.data(out_address'high - 24 downto 0) <= std_logic_vector(out_address(out_address'high downto 24));
                when 20 =>
                    io_resp.data <= std_logic_vector(out_end(7 downto 0));
                when 21 =>
                    io_resp.data <= std_logic_vector(out_end(15 downto 8));
                when 22 =>
                    io_resp.data <= std_logic_vector(out_end(23 downto 16));
                when 23 =>
                    io_resp.data(out_end'high - 24 downto 0) <= std_logic_vector(out_end(out_end'high downto 24));
                when 24 =>
                    io_resp.data(0) <= out_enable;
                    io_resp.data(1) <= out_continuous;
                when 25 =>
                    io_resp.data(1 downto 0) <= out_mode;
                when 31 =>
                    io_resp.data <= misc_io_i;

                when others =>
                    null;
                end case;
            elsif io_req.write='1' then
                io_resp.ack <= '1';
                case v_addr is
                when 0 =>
                    in_start(7 downto 0) <= unsigned(io_req.data);
                when 1 =>
                    in_start(15 downto 8) <= unsigned(io_req.data);
                when 2 =>
                    in_start(23 downto 16) <= unsigned(io_req.data);
                when 3 =>
                    in_start(in_start'high downto 24) <= unsigned(io_req.data(in_start'high-24 downto 0));
                when 4 =>
                    in_end(7 downto 0) <= unsigned(io_req.data);
                when 5 =>
                    in_end(15 downto 8) <= unsigned(io_req.data);
                when 6 =>
                    in_end(23 downto 16) <= unsigned(io_req.data);
                when 7 =>
                    in_end(in_end'high downto 24) <= unsigned(io_req.data(in_end'high-24 downto 0));
                when 8 =>
                    in_enable <= io_req.data(0);
                    in_continuous <= io_req.data(1);
                    if io_req.data(0) = '1' then
                        in_address <= in_start;
                    end if;
                when 9 =>
                    in_mode <= io_req.data(1 downto 0);
                when 16 =>
                    out_start(7 downto 0) <= unsigned(io_req.data);
                when 17 =>
                    out_start(15 downto 8) <= unsigned(io_req.data);
                when 18 =>
                    out_start(23 downto 16) <= unsigned(io_req.data);
                when 19 =>
                    out_start(out_start'high downto 24) <= unsigned(io_req.data(out_start'high-24 downto 0));
                when 20 =>
                    out_end(7 downto 0) <= unsigned(io_req.data);
                when 21 =>
                    out_end(15 downto 8) <= unsigned(io_req.data);
                when 22 =>
                    out_end(23 downto 16) <= unsigned(io_req.data);
                when 23 =>
                    out_end(out_end'high downto 24) <= unsigned(io_req.data(out_end'high-24 downto 0));
                when 24 =>
                    out_enable <= io_req.data(0);
                    out_continuous <= io_req.data(1);
                    if io_req.data(0) = '1' then
                        out_address <= out_start;
                    end if;
                when 25 =>
                    out_mode <= io_req.data(1 downto 0);
                when 31 =>
                    misc_io_i <= io_req.data;
                when others =>
                    null;
                end case;                    
            end if;

            if sys_reset='1' then
                state       <= idle;
                mem_req.request <= '0';
                in_enable   <= '0';
                in_continuous <= '0';
                in_address  <= (in_address'high => '1', others => '0');
                in_start    <= (in_address'high => '1', others => '0');
                in_end      <= (4 => '0', others => '1');
                out_enable  <= '0';
                out_continuous <= '0';
                out_address <= (out_address'high => '1', others => '0');
                out_start   <= (out_address'high => '1', others => '0');
                out_end     <= (4 => '0', others => '1');
                misc_io_i   <= (others => '0');
                in_mode     <= "00";
                out_mode    <= "00";
            end if;
        end if;
    end process;
    misc_io <= misc_io_i;

end gideon;
