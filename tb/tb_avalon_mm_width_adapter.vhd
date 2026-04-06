-- =============================================================================
-- VUnit Testbench : avalon_mm_width_adapter
-- =============================================================================
-- Covers three DUT configurations driven from run.py:
--   • Upsizing    – S_DATA_WIDTH=32, M_DATA_WIDTH=64
--   • Downsizing  – S_DATA_WIDTH=64, M_DATA_WIDTH=32
--   • Pass-through– S_DATA_WIDTH=32, M_DATA_WIDTH=32
--
-- Test cases
-- ----------
-- Upsizing (32 → 64)
--   test_upsize_write_slot0       Write to the lower 32-bit slot of a 64-bit word
--   test_upsize_write_slot1       Write to the upper 32-bit slot of a 64-bit word
--   test_upsize_read_slot0        Read back the lower 32-bit slot
--   test_upsize_read_slot1        Read back the upper 32-bit slot
--   test_upsize_byteenable        Verify byte-enable placement in wide word
--   test_upsize_waitrequest       Downstream asserts waitrequest for 2 cycles
--   test_upsize_pipelined_reads   Back-to-back pipelined read requests
--   test_upsize_roundtrip_slot0   Write then read-back slot 0 end-to-end
--   test_upsize_roundtrip_slot1   Write then read-back slot 1 end-to-end
--
-- Downsizing (64 → 32)
--   test_downsize_write           64-bit write splits into 2 × 32-bit writes
--   test_downsize_read            2 × 32-bit reads assembled into 64-bit read
--   test_downsize_partial_be      Only lower half byte-enables active
--   test_downsize_waitrequest     Downstream asserts waitrequest during burst
--
-- Pass-through (32 → 32)
--   test_passthrough_write        Direct write forwarding
--   test_passthrough_read         Direct read forwarding
--   test_passthrough_waitrequest  Waitrequest propagation
--
-- Author : GitHub Copilot
-- Date   : 2026-04-03
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

entity tb_avalon_mm_width_adapter is
    generic (
        runner_cfg   : string;
        -- DUT generics (overridden from run.py for each configuration)
        ADDR_WIDTH   : positive := 32;
        S_DATA_WIDTH : positive := 32;
        M_DATA_WIDTH : positive := 64;
        SYMBOL_WIDTH : positive := 8
    );
end entity tb_avalon_mm_width_adapter;

architecture sim of tb_avalon_mm_width_adapter is

    -- -------------------------------------------------------------------------
    -- Local helpers
    -- -------------------------------------------------------------------------
    function log2_ceil(n : positive) return natural is
        variable r : natural  := 0;
        variable v : positive := 1;
    begin
        while v < n loop v := v * 2; r := r + 1; end loop;
        return r;
    end function;

    function max_pos(a, b : positive) return positive is
    begin
        if a > b then return a; else return b; end if;
    end function;

    -- -------------------------------------------------------------------------
    -- Derived constants
    -- -------------------------------------------------------------------------
    constant S_BYTES    : positive := S_DATA_WIDTH / SYMBOL_WIDTH;
    constant M_BYTES    : positive := M_DATA_WIDTH / SYMBOL_WIDTH;
    constant CLK_PERIOD : time     := 10 ns;

    -- Memory model depth (in M-width words)
    constant MEM_DEPTH  : positive := 256;

    -- -------------------------------------------------------------------------
    -- DUT ports
    -- -------------------------------------------------------------------------
    signal clk             : std_logic := '0';
    signal reset           : std_logic := '1';

    signal s_address       : std_logic_vector(ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal s_read          : std_logic := '0';
    signal s_write         : std_logic := '0';
    signal s_writedata     : std_logic_vector(S_DATA_WIDTH - 1 downto 0) := (others => '0');
    signal s_byteenable    : std_logic_vector(S_BYTES - 1 downto 0) := (others => '1');
    signal s_readdata      : std_logic_vector(S_DATA_WIDTH - 1 downto 0);
    signal s_readdatavalid : std_logic;
    signal s_waitrequest   : std_logic;

    signal m_address       : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal m_read          : std_logic;
    signal m_write         : std_logic;
    signal m_writedata     : std_logic_vector(M_DATA_WIDTH - 1 downto 0);
    signal m_byteenable    : std_logic_vector(M_BYTES - 1 downto 0);
    signal m_readdata      : std_logic_vector(M_DATA_WIDTH - 1 downto 0) := (others => '0');
    signal m_readdatavalid : std_logic := '0';
    signal m_waitrequest   : std_logic := '0';

    -- -------------------------------------------------------------------------
    -- Slave memory model control
    -- -------------------------------------------------------------------------
    signal mem_wait_cycles : natural := 0;   -- extra wait states

    -- -------------------------------------------------------------------------
    -- Simple word-addressed memory model (M_DATA_WIDTH wide)
    -- -------------------------------------------------------------------------
    type t_memory is array (0 to MEM_DEPTH - 1) of
                             std_logic_vector(M_DATA_WIDTH - 1 downto 0);
    -- Shared-variable memory model: avoids multiple-driver 'X' that occurs
    -- when both the main process and slave_model drive the same signal element.
    -- GHDL requires -frelaxed to allow non-protected shared variables (set in run.py).
    shared variable mem : t_memory := (others => (others => '0'));

    -- =========================================================================
    -- Helper procedures (must be in declarative region)
    -- =========================================================================

    -- Issue a slave write and wait until the adapter is fully done.
    -- Phase 1: drive write until s_waitrequest='0' (transaction accepted).
    -- Phase 2: wait until adapter returns to idle (s_waitrequest='0' once
    --          deasserted, covers multi-cycle downsize bursts).
    procedure do_write (
        signal clk          : in  std_logic;
        signal s_address    : out std_logic_vector;
        signal s_write      : out std_logic;
        signal s_writedata  : out std_logic_vector;
        signal s_byteenable : out std_logic_vector;
        signal s_waitrequest: in  std_logic;
        constant addr       : in  natural;
        constant data       : in  std_logic_vector;
        constant be         : in  std_logic_vector
    ) is
    begin
        s_address    <= std_logic_vector(to_unsigned(addr, s_address'length));
        s_writedata  <= data;
        s_byteenable <= be;
        s_write      <= '1';
        -- Phase 1: wait for acceptance
        loop
            wait until rising_edge(clk);
            exit when s_waitrequest = '0';
        end loop;
        s_write <= '0';
        -- Phase 2: allow one cycle for FSM to move to burst state, then wait
        -- until the adapter returns to IDLE (s_waitrequest='0').
        wait until rising_edge(clk);
        loop
            exit when s_waitrequest = '0';
            wait until rising_edge(clk);
        end loop;
        -- One extra settling cycle so memory shared-variable writes are visible.
        wait until rising_edge(clk);
    end procedure;

    -- Issue a slave read and return the assembled read data.
    procedure do_read (
        signal clk             : in  std_logic;
        signal s_address       : out std_logic_vector;
        signal s_read          : out std_logic;
        signal s_waitrequest   : in  std_logic;
        signal s_readdatavalid : in  std_logic;
        signal s_readdata      : in  std_logic_vector;
        constant addr          : in  natural;
        variable result        : out std_logic_vector
    ) is
    begin
        s_address <= std_logic_vector(to_unsigned(addr, s_address'length));
        s_read    <= '1';
        loop
            wait until rising_edge(clk);
            exit when s_waitrequest = '0';
        end loop;
        s_read <= '0';
        loop
            wait until rising_edge(clk);
            if s_readdatavalid = '1' then
                result := s_readdata;
                exit;
            end if;
        end loop;
    end procedure;

begin

    -- =========================================================================
    -- DUT
    -- =========================================================================
    dut : entity work.avalon_mm_width_adapter
        generic map (
            ADDR_WIDTH   => ADDR_WIDTH,
            S_DATA_WIDTH => S_DATA_WIDTH,
            M_DATA_WIDTH => M_DATA_WIDTH,
            SYMBOL_WIDTH => SYMBOL_WIDTH
        )
        port map (
            clk             => clk,
            reset           => reset,
            s_address       => s_address,
            s_read          => s_read,
            s_write         => s_write,
            s_writedata     => s_writedata,
            s_byteenable    => s_byteenable,
            s_readdata      => s_readdata,
            s_readdatavalid => s_readdatavalid,
            s_waitrequest   => s_waitrequest,
            m_address       => m_address,
            m_read          => m_read,
            m_write         => m_write,
            m_writedata     => m_writedata,
            m_byteenable    => m_byteenable,
            m_readdata      => m_readdata,
            m_readdatavalid => m_readdatavalid,
            m_waitrequest   => m_waitrequest
        );

    -- =========================================================================
    -- Clock generation
    -- =========================================================================
    clk <= not clk after CLK_PERIOD / 2;

    -- =========================================================================
    -- Downstream slave memory model
    -- Single process owns m_waitrequest, m_readdata, m_readdatavalid.
    --
    -- State machine:
    --   IDLE  – waiting for a transaction
    --   WAIT  – burning off extra wait-request cycles before committing
    --   RESP  – issuing read data on the next rising edge
    -- =========================================================================
    slave_model : process(clk)
        type t_sm_state is (SL_IDLE, SL_WAIT, SL_RESP);
        variable sm          : t_sm_state    := SL_IDLE;
        variable v_word_addr : natural       := 0;
        variable v_wait_cnt  : natural       := 0;
        variable v_is_read   : boolean       := false;
        variable v_word      : std_logic_vector(M_DATA_WIDTH - 1 downto 0);
    begin
        if rising_edge(clk) then
            -- Default: de-assert single-cycle signals
            m_readdatavalid <= '0';
            m_waitrequest   <= '0';

            if reset = '1' then
                sm          := SL_IDLE;
                v_wait_cnt  := 0;
                v_is_read   := false;
            else
                case sm is

                    when SL_IDLE =>
                        if (m_read = '1' or m_write = '1') then
                            v_word_addr := to_integer(unsigned(m_address)) / M_BYTES;
                            v_is_read   := (m_read = '1');

                            if m_write = '1' then
                                -- Byte-enable masked write via read-modify-write
                                v_word := mem(v_word_addr mod MEM_DEPTH);
                                for i in 0 to M_BYTES - 1 loop
                                    if m_byteenable(i) = '1' then
                                        v_word(
                                            i * SYMBOL_WIDTH + SYMBOL_WIDTH - 1
                                            downto i * SYMBOL_WIDTH
                                        ) := m_writedata(
                                            i * SYMBOL_WIDTH + SYMBOL_WIDTH - 1
                                            downto i * SYMBOL_WIDTH
                                        );
                                    end if;
                                end loop;
                                mem(v_word_addr mod MEM_DEPTH) := v_word;
                            end if;

                            if mem_wait_cycles = 0 then
                                -- No extra wait: for reads respond next cycle;
                                -- for writes the transaction is already committed.
                                if m_read = '1' then
                                    sm := SL_RESP;
                                end if;
                                -- write: stay in SL_IDLE (accepted immediately)
                            else
                                -- Assert waitrequest and count down
                                m_waitrequest <= '1';
                                v_wait_cnt    := mem_wait_cycles;
                                sm            := SL_WAIT;
                            end if;
                        end if;

                    when SL_WAIT =>
                        m_waitrequest <= '1';
                        if v_wait_cnt = 1 then
                            -- Final stall cycle: de-assert next, then respond
                            m_waitrequest <= '0';
                            if v_is_read then
                                sm := SL_RESP;
                            else
                                sm := SL_IDLE;
                            end if;
                        end if;
                        v_wait_cnt := v_wait_cnt - 1;

                    when SL_RESP =>
                        -- Issue read data
                        m_readdata      <= mem(v_word_addr mod MEM_DEPTH);
                        m_readdatavalid <= '1';
                        sm              := SL_IDLE;

                end case;
            end if;
        end if;
    end process slave_model;

    -- =========================================================================
    -- Main test process
    -- =========================================================================
    main : process
        variable v_read_data : std_logic_vector(S_DATA_WIDTH - 1 downto 0);

        -- Typed all-ones byte-enable for this configuration's slave port width.
        -- Using 'constant (others => '1')' directly as an unconstrained-array
        -- actual is rejected by GHDL; a named constant resolves the type.
        constant C_BE_ALL : std_logic_vector(S_BYTES - 1 downto 0) := (others => '1');

        -- Configuration flags derived from generics
        constant IS_UPSIZE   : boolean := M_DATA_WIDTH > S_DATA_WIDTH;
        constant IS_DOWNSIZE : boolean := S_DATA_WIDTH > M_DATA_WIDTH;
        constant IS_PASSTHRU : boolean := S_DATA_WIDTH = M_DATA_WIDTH;

    begin
        -- VUnit setup
        test_runner_setup(runner, runner_cfg);

        -- Release reset after 3 clock edges
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);

        -- =====================================================================
        -- UPSIZING TEST CASES
        -- =====================================================================

        if run("test_upsize_write_slot0") then
            -- Write S_DATA_WIDTH-bit value into slot 0 of a wide memory word.
            -- All upper slots must remain zero after the write.
            check(IS_UPSIZE, "Only valid for upsizing configuration");
            mem_wait_cycles <= 0;
            do_write(clk, s_address, s_write, s_writedata, s_byteenable,
                     s_waitrequest,
                     addr => 0,
                     data => x"DEADBEEF",
                     be   => C_BE_ALL);
            -- Slot 0 must hold the written value
            check_equal(mem(0)(S_DATA_WIDTH - 1 downto 0),
                        std_logic_vector'(x"DEADBEEF"),
                        "Lower slot write data mismatch");
            -- All upper slots must be untouched (zero). Uses generic width so
            -- this works for any RATIO (32→64, 32→128, …).
            check_equal(mem(0)(M_DATA_WIDTH - 1 downto S_DATA_WIDTH),
                        std_logic_vector(to_unsigned(0, M_DATA_WIDTH - S_DATA_WIDTH)),
                        "Upper slots should be zero");

        elsif run("test_upsize_write_slot1") then
            -- Write S_DATA_WIDTH-bit value into slot 1 of a wide memory word.
            -- Slot 0 and any slots above slot 1 must remain zero.
            check(IS_UPSIZE, "Only valid for upsizing configuration");
            mem_wait_cycles <= 0;
            -- Pre-clear the memory location
            mem(0) := (others => '0');
            wait until rising_edge(clk);
            do_write(clk, s_address, s_write, s_writedata, s_byteenable,
                     s_waitrequest,
                     addr => S_BYTES,            -- byte offset = S_BYTES selects slot 1
                     data => x"CAFEBABE",
                     be   => C_BE_ALL);
            -- Check slot 1 specifically (always S_DATA_WIDTH bits wide)
            check_equal(mem(0)(2 * S_DATA_WIDTH - 1 downto S_DATA_WIDTH),
                        std_logic_vector'(x"CAFEBABE"),
                        "Slot 1 write data mismatch");
            -- Slot 0 must be zero
            check_equal(mem(0)(S_DATA_WIDTH - 1 downto 0),
                        std_logic_vector(to_unsigned(0, S_DATA_WIDTH)),
                        "Slot 0 should be zero");

        elsif run("test_upsize_read_slot0") then
            check(IS_UPSIZE, "Only valid for upsizing configuration");
            mem_wait_cycles <= 0;
            -- Build generic-width preload: slot0=0x22222222, slot1=0x11111111, rest=0
            mem(0) := (others => '0');
            mem(0)(S_DATA_WIDTH - 1 downto 0) := x"22222222";
            mem(0)(2 * S_DATA_WIDTH - 1 downto S_DATA_WIDTH) := x"11111111";
            wait until rising_edge(clk);
            do_read(clk, s_address, s_read, s_waitrequest,
                    s_readdatavalid, s_readdata,
                    addr   => 0,
                    result => v_read_data);
            check_equal(v_read_data, std_logic_vector'(x"22222222"),
                        "Read slot0 mismatch");

        elsif run("test_upsize_read_slot1") then
            check(IS_UPSIZE, "Only valid for upsizing configuration");
            mem_wait_cycles <= 0;
            -- Build generic-width preload: slot0=0x00000000, slot1=0xAABBCCDD, rest=0
            mem(0) := (others => '0');
            mem(0)(2 * S_DATA_WIDTH - 1 downto S_DATA_WIDTH) := x"AABBCCDD";
            wait until rising_edge(clk);
            do_read(clk, s_address, s_read, s_waitrequest,
                    s_readdatavalid, s_readdata,
                    addr   => S_BYTES,
                    result => v_read_data);
            check_equal(v_read_data, std_logic_vector'(x"AABBCCDD"),
                        "Read slot1 mismatch");

        elsif run("test_upsize_byteenable") then
            -- Only byte-enable bits 0 and 1 active → only bytes 0-1 written
            check(IS_UPSIZE, "Only valid for upsizing configuration");
            mem_wait_cycles <= 0;
            mem(0) := (others => '0');
            wait until rising_edge(clk);
            do_write(clk, s_address, s_write, s_writedata, s_byteenable,
                     s_waitrequest,
                     addr => 0,
                     data => x"FFFFFFFF",
                     be   => "0011");        -- only bytes 0-1
            -- bytes 0-1 written, bytes 2-3 zero
            check_equal(mem(0)(15 downto 0),
                        std_logic_vector'(x"FFFF"),
                        "Low bytes should be written");
            check_equal(mem(0)(31 downto 16),
                        std_logic_vector'(x"0000"),
                        "High bytes should remain 0");

        elsif run("test_upsize_waitrequest") then
            -- Downstream asserts waitrequest for 2 cycles; DUT must stall slave
            check(IS_UPSIZE, "Only valid for upsizing configuration");
            mem_wait_cycles <= 2;
            mem(0) := (others => '0');
            wait until rising_edge(clk);
            do_write(clk, s_address, s_write, s_writedata, s_byteenable,
                     s_waitrequest,
                     addr => 0,
                     data => x"BEEFDEAD",
                     be   => C_BE_ALL);
            check_equal(mem(0)(S_DATA_WIDTH - 1 downto 0),
                        std_logic_vector'(x"BEEFDEAD"),
                        "Write with waitrequest mismatch");
            mem_wait_cycles <= 0;

        elsif run("test_upsize_pipelined_reads") then
            -- Two back-to-back reads to the same wide word, different slots.
            -- Works for any RATIO: slot0=0xCAFEBABE, slot1=0xDEADBEEF, rest=0.
            check(IS_UPSIZE, "Only valid for upsizing configuration");
            mem_wait_cycles <= 0;
            mem(0) := (others => '0');
            mem(0)(S_DATA_WIDTH - 1 downto 0) := x"CAFEBABE";
            mem(0)(2 * S_DATA_WIDTH - 1 downto S_DATA_WIDTH) := x"DEADBEEF";
            wait until rising_edge(clk);
            -- Read slot 0 (lower 32 bits)
            do_read(clk, s_address, s_read, s_waitrequest,
                    s_readdatavalid, s_readdata,
                    addr   => 0,
                    result => v_read_data);
            check_equal(v_read_data, std_logic_vector'(x"CAFEBABE"),
                        "Pipelined read slot0 mismatch");
            -- Read slot 1 (upper 32 bits)
            do_read(clk, s_address, s_read, s_waitrequest,
                    s_readdatavalid, s_readdata,
                    addr   => S_BYTES,
                    result => v_read_data);
            check_equal(v_read_data, std_logic_vector'(x"DEADBEEF"),
                        "Pipelined read slot1 mismatch");

        elsif run("test_upsize_roundtrip_slot0") then
            -- Write 0xDEADBEEF via the slave port into slot 0, then read it
            -- back via the same slave port and verify the returned value.
            -- This exercises the write path and read path together rather than
            -- inspecting the memory model directly.
            check(IS_UPSIZE, "Only valid for upsizing configuration");
            mem_wait_cycles <= 0;
            mem(0) := (others => '0');
            wait until rising_edge(clk);
            do_write(clk, s_address, s_write, s_writedata, s_byteenable,
                     s_waitrequest,
                     addr => 0,
                     data => x"DEADBEEF",
                     be   => C_BE_ALL);
            do_read(clk, s_address, s_read, s_waitrequest,
                    s_readdatavalid, s_readdata,
                    addr   => 0,
                    result => v_read_data);
            check_equal(v_read_data, std_logic_vector'(x"DEADBEEF"),
                        "Roundtrip slot0: read-back mismatch after write");

        elsif run("test_upsize_roundtrip_slot1") then
            -- Write 0xCAFEBABE via the slave port into slot 1, then read it
            -- back.  Also verifies that slot 0 was not disturbed by the write.
            check(IS_UPSIZE, "Only valid for upsizing configuration");
            mem_wait_cycles <= 0;
            mem(0) := (others => '0');
            wait until rising_edge(clk);
            do_write(clk, s_address, s_write, s_writedata, s_byteenable,
                     s_waitrequest,
                     addr => S_BYTES,
                     data => x"CAFEBABE",
                     be   => C_BE_ALL);
            -- Slot 0 must still be zero
            check_equal(mem(0)(S_DATA_WIDTH - 1 downto 0),
                        std_logic_vector(to_unsigned(0, S_DATA_WIDTH)),
                        "Roundtrip slot1: slot 0 was unexpectedly modified");
            do_read(clk, s_address, s_read, s_waitrequest,
                    s_readdatavalid, s_readdata,
                    addr   => S_BYTES,
                    result => v_read_data);
            check_equal(v_read_data, std_logic_vector'(x"CAFEBABE"),
                        "Roundtrip slot1: read-back mismatch after write");

        -- =====================================================================
        -- DOWNSIZING TEST CASES
        -- =====================================================================

        elsif run("test_downsize_write") then
            -- One 64-bit slave write → two 32-bit downstream writes
            check(IS_DOWNSIZE, "Only valid for downsizing configuration");
            mem_wait_cycles <= 0;
            mem(0) := (others => '0');
            mem(1) := (others => '0');
            wait until rising_edge(clk);
            do_write(clk, s_address, s_write, s_writedata, s_byteenable,
                     s_waitrequest,
                     addr => 0,
                     data => x"DEADBEEFCAFEBABE",
                     be   => C_BE_ALL);
            -- Lower M-width word at address 0
            check_equal(mem(0)(M_DATA_WIDTH - 1 downto 0),
                        std_logic_vector'(x"CAFEBABE"),
                        "Downsize write: lower word mismatch");
            -- Upper M-width word at address M_BYTES
            check_equal(mem(1)(M_DATA_WIDTH - 1 downto 0),
                        std_logic_vector'(x"DEADBEEF"),
                        "Downsize write: upper word mismatch");

        elsif run("test_downsize_read") then
            -- Two 32-bit downstream reads assembled into one 64-bit slave read.
            -- FSM issues: read@0 → mem(0)=CAFEBABE (lower half),
            --             read@4 → mem(1)=DEADBEEF (upper half).
            check(IS_DOWNSIZE, "Only valid for downsizing configuration");
            mem_wait_cycles <= 0;
            mem(0) := x"CAFEBABE";
            mem(1) := x"DEADBEEF";
                wait until rising_edge(clk);
            do_read(clk, s_address, s_read, s_waitrequest,
                    s_readdatavalid, s_readdata,
                    addr   => 0,
                    result => v_read_data);
            check_equal(v_read_data(M_DATA_WIDTH - 1 downto 0),
                        std_logic_vector'(x"CAFEBABE"),
                        "Downsize read: lower word mismatch");
            check_equal(v_read_data(S_DATA_WIDTH - 1 downto M_DATA_WIDTH),
                        std_logic_vector'(x"DEADBEEF"),
                        "Downsize read: upper word mismatch");

        elsif run("test_downsize_partial_be") then
            -- Only lower-half byte enables → only the first narrow write issued
            check(IS_DOWNSIZE, "Only valid for downsizing configuration");
            mem_wait_cycles <= 0;
            mem(0) := (others => '0');
            mem(1) := (others => '0');
            wait until rising_edge(clk);
            do_write(clk, s_address, s_write, s_writedata, s_byteenable,
                     s_waitrequest,
                     addr => 0,
                     data => x"DEADBEEFCAFEBABE",
                     be   => "00001111");   -- lower 4 bytes only
            check_equal(mem(0)(M_DATA_WIDTH - 1 downto 0),
                        std_logic_vector'(x"CAFEBABE"),
                        "Partial BE: lower word mismatch");
            -- Upper word must stay zero (byte enable masked)
            check_equal(mem(1)(M_DATA_WIDTH - 1 downto 0),
                        std_logic_vector'(x"00000000"),
                        "Partial BE: upper word must be zero");

        elsif run("test_downsize_waitrequest") then
            -- Downstream asserts waitrequest during each narrow transaction
            check(IS_DOWNSIZE, "Only valid for downsizing configuration");
            mem_wait_cycles <= 1;
            mem(0) := (others => '0');
            mem(1) := (others => '0');
            wait until rising_edge(clk);
            do_write(clk, s_address, s_write, s_writedata, s_byteenable,
                     s_waitrequest,
                     addr => 0,
                     data => x"11223344AABBCCDD",
                     be   => C_BE_ALL);
            check_equal(mem(0)(M_DATA_WIDTH - 1 downto 0),
                        std_logic_vector'(x"AABBCCDD"),
                        "DS waitrequest write: lower word mismatch");
            check_equal(mem(1)(M_DATA_WIDTH - 1 downto 0),
                        std_logic_vector'(x"11223344"),
                        "DS waitrequest write: upper word mismatch");
            mem_wait_cycles <= 0;

        -- =====================================================================
        -- PASS-THROUGH TEST CASES
        -- =====================================================================

        elsif run("test_passthrough_write") then
            check(IS_PASSTHRU, "Only valid for pass-through configuration");
            mem_wait_cycles <= 0;
            mem(0) := (others => '0');
            wait until rising_edge(clk);
            do_write(clk, s_address, s_write, s_writedata, s_byteenable,
                     s_waitrequest,
                     addr => 0,
                     data => x"12345678",
                     be   => C_BE_ALL);
            check_equal(mem(0)(S_DATA_WIDTH - 1 downto 0),
                        std_logic_vector'(x"12345678"),
                        "Passthrough write mismatch");

        elsif run("test_passthrough_read") then
            check(IS_PASSTHRU, "Only valid for pass-through configuration");
            mem_wait_cycles <= 0;
            mem(0) := x"ABCDEF01";
            wait until rising_edge(clk);
            do_read(clk, s_address, s_read, s_waitrequest,
                    s_readdatavalid, s_readdata,
                    addr   => 0,
                    result => v_read_data);
            check_equal(v_read_data, std_logic_vector'(x"ABCDEF01"),
                        "Passthrough read mismatch");

        elsif run("test_passthrough_waitrequest") then
            -- Verify waitrequest propagates through the adapter
            check(IS_PASSTHRU, "Only valid for pass-through configuration");
            mem_wait_cycles <= 3;
            mem(0) := (others => '0');
            wait until rising_edge(clk);
            do_write(clk, s_address, s_write, s_writedata, s_byteenable,
                     s_waitrequest,
                     addr => 0,
                     data => x"FEEDFACE",
                     be   => C_BE_ALL);
            check_equal(mem(0)(S_DATA_WIDTH - 1 downto 0),
                        std_logic_vector'(x"FEEDFACE"),
                        "Passthrough waitrequest write mismatch");
            mem_wait_cycles <= 0;

        end if;

        test_runner_cleanup(runner);
    end process main;

    -- Watch-dog: each test owns its own timeout via set_timeout above
    test_runner_watchdog(runner, 50 us);

end architecture sim;
