library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top is
    port (
        clk100Mhz    : in  std_logic;
        btnRst       : in  std_logic;
        swMode       : in  std_logic; 
        uartRx       : in  std_logic;  
        uartTx       : out std_logic; 
        vgaHs        : out std_logic;
        vgaVs        : out std_logic;
        vgaR         : out std_logic_vector(3 downto 0);
        vgaG         : out std_logic_vector(3 downto 0);
        vgaB         : out std_logic_vector(3 downto 0);
        audioPwm     : out std_logic;
        ampGain      : out std_logic;
        ampShutdownN : out std_logic
    );
end entity top;

architecture behavioral of top is

    constant gridBits : integer := 6;

    component blk_mem_gen_0 is
        port (
            clka  : in  std_logic;
            addra : in  std_logic_vector(10 downto 0);
            douta : out std_logic_vector(23 downto 0)
        );
    end component blk_mem_gen_0;

    signal clkDiv         : unsigned(1 downto 0) := (others => '0');
    signal pixelEnable    : std_logic := '0';
    signal customPhaseInc : unsigned(31 downto 0);
    signal songRomAddr    : std_logic_vector(10 downto 0);
    signal songRomData    : std_logic_vector(23 downto 0);
    signal audioSample    : signed(15 downto 0);
    signal sampleValid    : std_logic;
    signal solverBusy     : std_logic;
    signal vgaGridX       : unsigned(gridBits - 1 downto 0);
    signal vgaGridY       : unsigned(gridBits - 1 downto 0);
    signal sandValue      : unsigned(15 downto 0);

begin

    ampGain      <= '0';
    ampShutdownN <= '1';
    -- Create a 25 MHz tick for the VGA display (1 pulse every 4 clock cycles)
    process(clk100Mhz)

        procedure updatePixelClockEnable is
        begin
            clkDiv <= clkDiv + 1;
            if clkDiv = "11" then
                pixelEnable <= '1';
            else
                pixelEnable <= '0';
            end if;
        end procedure;

    begin
        if rising_edge(clk100Mhz) then
            if btnRst = '1' then
                clkDiv      <= (others => '0');
                pixelEnable <= '0';
            else
                updatePixelClockEnable;
            end if;
        end if;
    end process;

    uartParserInst : entity work.uartFreqParser
        port map (
            systemClock => clk100Mhz,
            syncReset   => btnRst,
            swMode      => swMode,
            rxPin       => uartRx,
            txPin       => uartTx,
            phaseInc    => customPhaseInc
        );

    songRomInst : blk_mem_gen_0
        port map (
            clka  => clk100Mhz,
            addra => songRomAddr,
            douta => songRomData
        );

    audioCtrlInst : entity work.audioModeController
        port map (
            systemClock    => clk100Mhz,
            syncReset      => btnRst,
            swMode         => swMode,
            customPhaseInc => customPhaseInc,
            romAddr        => songRomAddr,
            romData        => songRomData,
            audioSample    => audioSample,
            sampleValid    => sampleValid,
            audioPwm       => audioPwm
        );

    -- Chladni Plate Wave Simulator 64x64 Grid
    waveSolverInst : entity work.waveChladniSolver
        generic map (
            gridBits       => gridBits,
            dataWidth      => 24,
            stiffnessShift => 4,
            dampingShift   => 9,
            sandDecayShift => 6,
            exciteX        => 32,
            exciteY        => 32
        )
        port map (
            systemClock    => clk100Mhz,
            syncReset      => btnRst,
            audioSampleIn  => audioSample,
            sampleValid    => sampleValid,
            solverBusy     => solverBusy,
            vgaGridX       => vgaGridX,
            vgaGridY       => vgaGridY,
            sandAmplitude  => sandValue
        );

    -- VGA Heat Map Screen Renderer 640x480 60 Hz
    vgaDisplayInst : entity work.vgaChladniDisplay
        generic map (
            gridAddressBits => gridBits
        )
        port map (
            systemClock   => clk100Mhz,
            pixelEnable   => pixelEnable,
            syncReset     => btnRst,
            gridX         => vgaGridX,
            gridY         => vgaGridY,
            sandAmplitude => sandValue,
            sandThreshold => to_unsigned(600, 16),
            vgaHsync      => vgaHs,
            vgaVsync      => vgaVs,
            vgaRed        => vgaR,
            vgaGreen      => vgaG,
            vgaBlue       => vgaB
        );

end architecture behavioral;