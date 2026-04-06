-- =============================================================================
-- Avalon-MM Configurable Width Adapter
-- =============================================================================
-- Description:
--   Adapts between an Avalon-MM slave port and an Avalon-MM master port that
--   operate at different data widths.  The ratio (S_DATA_WIDTH / M_DATA_WIDTH
--   or its inverse) must be a power of two.
--
--   Upsizing  (M_DATA_WIDTH > S_DATA_WIDTH):
--     Each narrow slave transaction maps to one wide master transaction.
--     The correct sub-word slot is selected via the least-significant address
--     bits and the byte-enables are positioned accordingly.
--
--   Downsizing (S_DATA_WIDTH > M_DATA_WIDTH):
--     One wide slave transaction is broken into RATIO consecutive narrow
--     master transactions.  The slave waitrequest is asserted until all
--     sub-transactions have completed.
--
--   Same width (M_DATA_WIDTH = S_DATA_WIDTH):
--     All signals are wired through combinationally.
--
-- Generics:
--   ADDR_WIDTH   – address bus width in bits (byte address, default 32)
--   S_DATA_WIDTH – slave-side  data bus width in bits (default 32)
--   M_DATA_WIDTH – master-side data bus width in bits (default 64)
--   SYMBOL_WIDTH – bits per addressable unit / symbol   (default  8)
--
-- Constraints:
--   * S_DATA_WIDTH and M_DATA_WIDTH must be multiples of SYMBOL_WIDTH.
--   * The larger of the two must be an exact power-of-two multiple of the
--     smaller one (ratio 1, 2, 4, 8 …).
--
-- Author : GitHub Copilot
-- Date   : 2026-04-03
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity avalon_mm_width_adapter is
    generic (
        ADDR_WIDTH   : positive := 32;
        S_DATA_WIDTH : positive := 32;
        M_DATA_WIDTH : positive := 64;
        SYMBOL_WIDTH : positive := 8
    );
    port (
        clk   : in std_logic;
        reset : in std_logic;

        -- ----------------------------------------------------------------
        -- Slave port  (upstream – the master that drives this adapter)
        -- ----------------------------------------------------------------
        s_address       : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
        s_read          : in  std_logic;
        s_write         : in  std_logic;
        s_writedata     : in  std_logic_vector(S_DATA_WIDTH - 1 downto 0);
        s_byteenable    : in  std_logic_vector(S_DATA_WIDTH / SYMBOL_WIDTH - 1 downto 0);
        s_readdata      : out std_logic_vector(S_DATA_WIDTH - 1 downto 0);
        s_readdatavalid : out std_logic;
        s_waitrequest   : out std_logic;

        -- ----------------------------------------------------------------
        -- Master port (downstream – the slave that this adapter drives)
        -- ----------------------------------------------------------------
        m_address       : out std_logic_vector(ADDR_WIDTH - 1 downto 0);
        m_read          : out std_logic;
        m_write         : out std_logic;
        m_writedata     : out std_logic_vector(M_DATA_WIDTH - 1 downto 0);
        m_byteenable    : out std_logic_vector(M_DATA_WIDTH / SYMBOL_WIDTH - 1 downto 0);
        m_readdata      : in  std_logic_vector(M_DATA_WIDTH - 1 downto 0);
        m_readdatavalid : in  std_logic;
        m_waitrequest   : in  std_logic
    );
end entity avalon_mm_width_adapter;

-- =============================================================================
architecture rtl of avalon_mm_width_adapter is

    -- -------------------------------------------------------------------------
    -- Package-level helpers
    -- -------------------------------------------------------------------------
    function log2_ceil(n : positive) return natural is
        variable r : natural := 0;
        variable v : positive := 1;
    begin
        while v < n loop
            v := v * 2;
            r := r + 1;
        end loop;
        return r;
    end function;

    function max_int(a, b : natural) return natural is
    begin
        if a > b then return a; else return b; end if;
    end function;

    function min_int(a, b : natural) return natural is
    begin
        if a < b then return a; else return b; end if;
    end function;

    -- -------------------------------------------------------------------------
    -- Derived constants
    -- -------------------------------------------------------------------------
    constant S_BYTES   : positive := S_DATA_WIDTH / SYMBOL_WIDTH;
    constant M_BYTES   : positive := M_DATA_WIDTH / SYMBOL_WIDTH;
    constant MAX_WIDTH : positive := max_int(S_DATA_WIDTH, M_DATA_WIDTH);
    constant MIN_WIDTH : positive := min_int(S_DATA_WIDTH, M_DATA_WIDTH);
    constant RATIO     : positive := MAX_WIDTH / MIN_WIDTH;         -- ≥ 1
    constant LOG2_RATIO: natural  := log2_ceil(RATIO);

    -- Byte counts
    constant MAX_BYTES : positive := max_int(S_BYTES, M_BYTES);
    constant MIN_BYTES : positive := min_int(S_BYTES, M_BYTES);

    -- -------------------------------------------------------------------------
    -- Downsize FSM type  (only used when S > M)
    -- -------------------------------------------------------------------------
    -- Sequential (non-pipelined) narrow-transaction issuer.
    -- States:
    --   ST_IDLE        : waiting for a slave transaction
    --   ST_WRITE_BURST : issuing narrow writes sequentially (one per cycle)
    --   ST_READ_ISSUE  : issuing a single narrow read
    --   ST_READ_WAIT   : waiting for the narrow read response before advancing
    -- -------------------------------------------------------------------------
    type t_ds_state is (ST_IDLE, ST_WRITE_BURST, ST_READ_ISSUE, ST_READ_WAIT);

    -- -------------------------------------------------------------------------
    -- Signals – downsizing path
    -- -------------------------------------------------------------------------
    signal ds_state      : t_ds_state;
    signal ds_idx        : natural range 0 to RATIO - 1;
    signal ds_addr_base  : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    signal ds_wdata_reg  : std_logic_vector(S_DATA_WIDTH - 1 downto 0);
    signal ds_be_reg     : std_logic_vector(S_BYTES - 1 downto 0);
    signal ds_rdata_acc  : std_logic_vector(S_DATA_WIDTH - 1 downto 0);

    -- -------------------------------------------------------------------------
    -- Signals – upsizing path
    -- -------------------------------------------------------------------------
    -- Sub-word index: which S-width slot within the M-width word
    signal us_sub_idx    : natural range 0 to RATIO - 1;

    -- -------------------------------------------------------------------------
    -- Pending read-data tracking (upsizing pipelined reads)
    -- -------------------------------------------------------------------------
    -- We keep a small FIFO of sub-word indices so we can demux read-data even
    -- when multiple reads are pipelined.  Depth = 16 is sufficient for typical
    -- Avalon pipelines; increase if needed.
    constant PIPE_DEPTH : positive := 16;
    type t_idx_fifo is array (0 to PIPE_DEPTH - 1) of
                               natural range 0 to RATIO - 1;
    signal us_idx_fifo   : t_idx_fifo;
    signal us_fifo_wr    : natural range 0 to PIPE_DEPTH - 1 := 0;
    signal us_fifo_rd    : natural range 0 to PIPE_DEPTH - 1 := 0;

begin

    -- =========================================================================
    -- UPSIZING  (M_DATA_WIDTH > S_DATA_WIDTH) – combinational address mapping
    -- plus registered sub-word index pipeline for read-data demux.
    -- =========================================================================
    gen_upsize : if M_DATA_WIDTH > S_DATA_WIDTH generate

        -- Sub-word index comes from address bits that select the narrow slot
        -- inside the wide word.  Address bits [log2(M_BYTES)-1 : log2(S_BYTES)]
        -- give us a RATIO-wide index.  Because addresses are byte-addressed the
        -- shift equals log2(S_BYTES).
        us_sub_idx <= to_integer(
            unsigned(s_address(log2_ceil(M_BYTES) - 1 downto log2_ceil(S_BYTES)))
        );

        -- ---- Registered sub-word index FIFO (write pointer advances on
        --      accepted read requests, read pointer advances on readdatavalid)
        proc_us_fifo : process(clk)
        begin
            if rising_edge(clk) then
                if reset = '1' then
                    us_fifo_wr <= 0;
                    us_fifo_rd <= 0;
                else
                    -- Push: accepted read request (read & ~waitrequest)
                    if s_read = '1' and m_waitrequest = '0' then
                        us_idx_fifo(us_fifo_wr) <= us_sub_idx;
                        if us_fifo_wr = PIPE_DEPTH - 1 then
                            us_fifo_wr <= 0;
                        else
                            us_fifo_wr <= us_fifo_wr + 1;
                        end if;
                    end if;
                    -- Pop: read data arrives
                    if m_readdatavalid = '1' then
                        if us_fifo_rd = PIPE_DEPTH - 1 then
                            us_fifo_rd <= 0;
                        else
                            us_fifo_rd <= us_fifo_rd + 1;
                        end if;
                    end if;
                end if;
            end if;
        end process;

        -- ---- Combinational outputs ----
        proc_us_comb : process(s_address, s_read, s_write, s_writedata,
                               s_byteenable, m_readdata, m_readdatavalid,
                               m_waitrequest, us_sub_idx, us_idx_fifo, us_fifo_rd)
            variable v_wr_data : std_logic_vector(M_DATA_WIDTH - 1 downto 0);
            variable v_wr_be   : std_logic_vector(M_BYTES - 1 downto 0);
            variable v_rd_idx  : natural range 0 to RATIO - 1;
            variable v_rd_lo   : natural;
            variable v_maddr   : std_logic_vector(ADDR_WIDTH - 1 downto 0);
            constant LM : natural := log2_ceil(M_BYTES);  -- log2 of M byte width
        begin
            -- Align slave address to the M-data-width boundary:
            -- clear the lower log2(M_BYTES) address bits.
            v_maddr := s_address;
            v_maddr(LM - 1 downto 0) := (others => '0');
            m_address    <= v_maddr;
            m_read       <= s_read;
            m_write      <= s_write;
            s_waitrequest <= m_waitrequest;

            -- Build write-data and byte-enable word
            v_wr_data := (others => '0');
            v_wr_be   := (others => '0');
            v_wr_data(us_sub_idx * S_DATA_WIDTH + S_DATA_WIDTH - 1
                      downto us_sub_idx * S_DATA_WIDTH) := s_writedata;
            v_wr_be(us_sub_idx * S_BYTES + S_BYTES - 1
                    downto us_sub_idx * S_BYTES)         := s_byteenable;
            m_writedata  <= v_wr_data;
            m_byteenable <= v_wr_be;

            -- Demux read-data using the stored sub-word index
            v_rd_idx := us_idx_fifo(us_fifo_rd);
            v_rd_lo  := v_rd_idx * S_DATA_WIDTH;
            s_readdata      <= m_readdata(v_rd_lo + S_DATA_WIDTH - 1 downto v_rd_lo);
            s_readdatavalid <= m_readdatavalid;
        end process;

    end generate gen_upsize;

    -- =========================================================================
    -- DOWNSIZING  (S_DATA_WIDTH > M_DATA_WIDTH) – FSM drives RATIO consecutive
    -- narrow master transactions for every wide slave transaction.
    -- Uses a fully sequential (non-pipelined) approach: one narrow transaction
    -- at a time, completing each read before issuing the next.
    -- =========================================================================
    gen_downsize : if S_DATA_WIDTH > M_DATA_WIDTH generate

        proc_ds_fsm : process(clk)
            variable v_lo_data : natural;
        begin
            if rising_edge(clk) then
                if reset = '1' then
                    ds_state    <= ST_IDLE;
                    ds_idx      <= 0;
                    ds_rdata_acc <= (others => '0');
                else
                    case ds_state is

                        -- --------------------------------------------------------
                        -- Accept the incoming slave transaction and latch it
                        -- --------------------------------------------------------
                        when ST_IDLE =>
                            if s_write = '1' or s_read = '1' then
                                ds_addr_base <= s_address;
                                ds_wdata_reg <= s_writedata;
                                ds_be_reg    <= s_byteenable;
                                ds_idx       <= 0;
                                if s_write = '1' then
                                    ds_state <= ST_WRITE_BURST;
                                else
                                    ds_rdata_acc <= (others => '0');
                                    ds_state     <= ST_READ_ISSUE;
                                end if;
                            end if;

                        -- --------------------------------------------------------
                        -- Issue narrow writes one at a time
                        -- --------------------------------------------------------
                        when ST_WRITE_BURST =>
                            if m_waitrequest = '0' then
                                if ds_idx = RATIO - 1 then
                                    ds_state <= ST_IDLE;
                                    ds_idx   <= 0;
                                else
                                    ds_idx <= ds_idx + 1;
                                end if;
                            end if;

                        -- --------------------------------------------------------
                        -- Issue a single narrow read and wait for it to be accepted
                        -- --------------------------------------------------------
                        when ST_READ_ISSUE =>
                            if m_waitrequest = '0' then
                                -- Read request accepted – wait for response
                                ds_state <= ST_READ_WAIT;
                            end if;

                        -- --------------------------------------------------------
                        -- Wait for the narrow read response, accumulate, advance
                        -- --------------------------------------------------------
                        when ST_READ_WAIT =>
                            if m_readdatavalid = '1' then
                                v_lo_data := ds_idx * M_DATA_WIDTH;
                                ds_rdata_acc(v_lo_data + M_DATA_WIDTH - 1
                                             downto v_lo_data) <= m_readdata;
                                if ds_idx = RATIO - 1 then
                                    ds_state <= ST_IDLE;
                                    ds_idx   <= 0;
                                else
                                    ds_idx   <= ds_idx + 1;
                                    ds_state <= ST_READ_ISSUE;
                                end if;
                            end if;

                    end case;
                end if;
            end if;
        end process proc_ds_fsm;

        -- ---- Combinational output mux ----------------------------------------
        proc_ds_comb : process(ds_state, ds_idx, ds_addr_base, ds_wdata_reg,
                               ds_be_reg, ds_rdata_acc,
                               s_address, s_read, s_write, s_writedata,
                               s_byteenable, m_waitrequest, m_readdatavalid,
                               m_readdata)
            variable v_lo_be   : natural;
            variable v_lo_data : natural;
            variable v_idx_be  : natural;
            variable v_idx_dat : natural;
        begin
            -- Defaults
            m_address       <= (others => '0');
            m_read          <= '0';
            m_write         <= '0';
            m_writedata     <= (others => '0');
            m_byteenable    <= (others => '1');
            s_waitrequest   <= '1';
            s_readdata      <= (others => '0');
            s_readdatavalid <= '0';

            case ds_state is

                -- ----------------------------------------------------------------
                when ST_IDLE =>
                    -- Adapter is ready: assert waitrequest='0'.
                    -- The upstream master's transaction is captured (latched) on
                    -- the rising edge when it sees waitrequest='0'.  On the next
                    -- clock the FSM is in WRITE_BURST / READ_ISSUE and asserts
                    -- waitrequest='1' to stall the master while sub-transactions
                    -- are in progress.
                    -- We do NOT drive the downstream master here to prevent
                    -- issuing sub-transaction 0 before the registered state
                    -- has advanced.
                    s_waitrequest <= '0';

                -- ----------------------------------------------------------------
                when ST_WRITE_BURST =>
                    v_lo_be   := ds_idx * M_BYTES;
                    v_lo_data := ds_idx * M_DATA_WIDTH;
                    v_idx_be  := v_lo_be   + M_BYTES      - 1;
                    v_idx_dat := v_lo_data + M_DATA_WIDTH - 1;
                    m_address    <= std_logic_vector(
                                      unsigned(ds_addr_base) +
                                      to_unsigned(ds_idx * M_BYTES, ADDR_WIDTH));
                    m_write      <= '1';
                    m_byteenable <= ds_be_reg  (v_idx_be  downto v_lo_be  );
                    m_writedata  <= ds_wdata_reg(v_idx_dat downto v_lo_data);
                    s_waitrequest <= '1';
                    -- Release slave only when final sub-transaction is accepted
                    if ds_idx = RATIO - 1 and m_waitrequest = '0' then
                        s_waitrequest <= '0';
                    end if;

                -- ----------------------------------------------------------------
                when ST_READ_ISSUE =>
                    m_address    <= std_logic_vector(
                                      unsigned(ds_addr_base) +
                                      to_unsigned(ds_idx * M_BYTES, ADDR_WIDTH));
                    m_read       <= '1';
                    m_byteenable <= (others => '1');
                    s_waitrequest <= '1';

                -- ----------------------------------------------------------------
                when ST_READ_WAIT =>
                    -- Not driving master; waiting for readdatavalid
                    s_waitrequest <= '1';
                    -- On the final beat, assemble the read data word
                    if m_readdatavalid = '1' and ds_idx = RATIO - 1 then
                        -- Combine already-accumulated words with the last beat
                        s_readdata <= m_readdata &
                                      ds_rdata_acc(ds_idx * M_DATA_WIDTH - 1 downto 0);
                        s_readdatavalid <= '1';
                        s_waitrequest   <= '0';
                    end if;

            end case;
        end process proc_ds_comb;

    end generate gen_downsize;

    -- =========================================================================
    -- SAME WIDTH – direct wire-through
    -- =========================================================================
    gen_passthrough : if S_DATA_WIDTH = M_DATA_WIDTH generate

        m_address       <= s_address;
        m_read          <= s_read;
        m_write         <= s_write;
        m_writedata     <= s_writedata;
        m_byteenable    <= s_byteenable;
        s_readdata      <= m_readdata;
        s_readdatavalid <= m_readdatavalid;
        s_waitrequest   <= m_waitrequest;

    end generate gen_passthrough;

end architecture rtl;
