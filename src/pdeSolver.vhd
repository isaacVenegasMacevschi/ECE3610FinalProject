library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity waveChladniSolver is
    generic (
        gridBits       : integer := 6;   -- 2^6 = 64x64 plate grid
        dataWidth      : integer := 24;  -- 24-bit signed fixed-point displacement
        stiffnessShift : integer := 4;   -- Stiffness mu = 2^-4
        dampingShift   : integer := 8;   -- Velocity damping alpha = 2^-8
        sandDecayShift : integer := 11;  -- Sand decay const = 2^-11
        exciteX        : integer := 32;
        exciteY        : integer := 32
    );
    port (
        systemClock    : in  std_logic;
        syncReset      : in  std_logic;
        audioSampleIn  : in  signed(15 downto 0);
        sampleValid    : in  std_logic;
        solverBusy     : out std_logic;
        vgaGridX       : in  unsigned(gridBits - 1 downto 0);
        vgaGridY       : in  unsigned(gridBits - 1 downto 0);
        sandAmplitude  : out unsigned(15 downto 0)
    );
end entity waveChladniSolver;

architecture behavioral of waveChladniSolver is

    constant gridSize      : integer := 2 ** gridBits;
    constant totalCells    : integer := gridSize * gridSize;
    constant totalSteps    : integer := totalCells + gridSize + 6;
    constant calcWidth     : integer := dataWidth + 4;
    constant maxWave       : signed(calcWidth - 1 downto 0) := to_signed((2 ** (dataWidth - 1)) - 1, calcWidth);
    constant minWave       : signed(calcWidth - 1 downto 0) := to_signed(-(2 ** (dataWidth - 1)), calcWidth);

    type waveRamArray      is array (0 to totalCells - 1) of signed(dataWidth - 1 downto 0);
    type sandRamArray      is array (0 to totalCells - 1) of unsigned(15 downto 0);
    type lineBufArray      is array (0 to gridSize - 1) of signed(dataWidth - 1 downto 0);
    type windowRowArray    is array (0 to 2) of signed(dataWidth - 1 downto 0);
    type window3x3Array    is array (0 to 2) of windowRowArray;

    signal currWaveRam     : waveRamArray   := (others => (others => '0'));
    signal prevWaveRam     : waveRamArray   := (others => (others => '0'));
    signal sandSolverRam   : sandRamArray   := (others => (others => '0'));
    signal sandVgaRam      : sandRamArray   := (others => (others => '0'));

    attribute ram_style : string;
    attribute ram_style of currWaveRam   : signal is "block";
    attribute ram_style of prevWaveRam   : signal is "block";
    attribute ram_style of sandSolverRam : signal is "block";
    attribute ram_style of sandVgaRam    : signal is "block";

    signal upperLineBuf    : lineBufArray   := (others => (others => '0'));
    signal lowerLineBuf    : lineBufArray   := (others => (others => '0'));
    signal window3x3       : window3x3Array := (others => (others => (others => '0')));

    signal isRunning       : std_logic := '0';
    signal stepCnt         : unsigned((2 * gridBits) + 1 downto 0) := (others => '0');
    signal latchedSample   : signed(15 downto 0) := (others => '0');

    signal currReadAddr    : unsigned((2 * gridBits) - 1 downto 0) := (others => '0');
    signal prevReadAddr    : unsigned((2 * gridBits) - 1 downto 0) := (others => '0');
    signal currWaveRead    : signed(dataWidth - 1 downto 0) := (others => '0');
    signal prevWaveRead    : signed(dataWidth - 1 downto 0) := (others => '0');
    signal sandRead        : unsigned(15 downto 0) := (others => '0');

    signal validS1         : std_logic := '0';
    signal xS1             : unsigned(gridBits - 1 downto 0) := (others => '0');

    signal validS2A        : std_logic := '0';
    signal xS2A            : unsigned(gridBits - 1 downto 0) := (others => '0');
    signal yS2A            : unsigned(gridBits - 1 downto 0) := (others => '0');

    signal validS2B        : std_logic := '0';
    signal xS2B            : unsigned(gridBits - 1 downto 0) := (others => '0');
    signal yS2B            : unsigned(gridBits - 1 downto 0) := (others => '0');
    signal rawWaveS2B      : signed(calcWidth - 1 downto 0) := (others => '0');
    signal currWaveS2B     : signed(dataWidth - 1 downto 0) := (others => '0');
    signal sandReadS2B     : unsigned(15 downto 0) := (others => '0');

    signal validS3         : std_logic := '0';
    signal xS3             : unsigned(gridBits - 1 downto 0) := (others => '0');
    signal yS3             : unsigned(gridBits - 1 downto 0) := (others => '0');
    signal nextWaveS3      : signed(dataWidth - 1 downto 0) := (others => '0');
    signal currWaveS3      : signed(dataWidth - 1 downto 0) := (others => '0');
    signal nextSandS3      : unsigned(15 downto 0) := (others => '0');

    pure function isBorder(cellX, cellY : unsigned(gridBits - 1 downto 0)) return boolean is
    begin
        return (cellX = 0) or (cellX = gridSize - 1) or
               (cellY = 0) or (cellY = gridSize - 1);
    end function;

    pure function isExciteCenter(cellX, cellY : unsigned(gridBits - 1 downto 0)) return boolean is
    begin
        return (cellX = to_unsigned(exciteX, gridBits)) and
               (cellY = to_unsigned(exciteY, gridBits));
    end function;

    -- Difference equation is as followed:
    -- u_{i,j}^{n+1} = u_{i,j}^n + (1 - gamma)*(u_{i,j}^n - u_{i,j}^{n-1}) + alpha * nabla^2(u_{i,j}^n) + S_{i,j}^n
    -- where gamma = 2^(-dampingShift), alpha = 2^(-stiffnessShift) = (c * dt / dx)^2
    pure function solveWave(
        win         : window3x3Array;
        prevVal     : signed(dataWidth - 1 downto 0);     -- u_{i,j}^{n-1}
        sample      : signed(15 downto 0);
        exciteOn    : boolean
    ) return signed is
        variable center      : signed(calcWidth - 1 downto 0);
        variable neighbors   : signed(calcWidth - 1 downto 0);
        variable laplacian   : signed(calcWidth - 1 downto 0);
        variable velocity    : signed(calcWidth - 1 downto 0);
        variable dampedVel   : signed(calcWidth - 1 downto 0);
        variable force       : signed(calcWidth - 1 downto 0);
    begin
        -- u_{i,j}^n
        center    := resize(win(1)(1), calcWidth);

        -- u_{i-1,j}^n + u_{i+1,j}^n + u_{i,j-1}^n + u_{i,j+1}^n
        neighbors := resize(win(0)(1), calcWidth) + resize(win(2)(1), calcWidth) +
                     resize(win(1)(0), calcWidth) + resize(win(1)(2), calcWidth);

        -- nabla^2(u^n) = neighbors - 4 * u_{i,j}^n
        laplacian := neighbors - shift_left(center, 2);

        -- v^n = u_{i,j}^n - u_{i,j}^{n-1}
        velocity  := center - resize(prevVal, calcWidth);

        -- (1 - gamma) * v^n
        dampedVel := velocity - shift_right(velocity, dampingShift);

        -- S_{i,j}^n (sample / 4 at exciter, 0 elsewhere)
        if exciteOn then
            force := resize(shift_right(sample, 2), calcWidth);
        else
            force := (others => '0');
        end if;

        -- u_{i,j}^{n+1} = u^n + (1 - gamma)*v^n + alpha*nabla^2(u^n) + S^n
        return center + dampedVel + shift_right(laplacian, stiffnessShift) + force;
    end function;

    pure function clampWave(
        rawVal    : signed(calcWidth - 1 downto 0);
        onBorder  : boolean
    ) return signed is
    begin
        if onBorder then
            return to_signed(0, dataWidth);
        elsif rawVal > maxWave then
            return maxWave(dataWidth - 1 downto 0);
        elsif rawVal < minWave then
            return minWave(dataWidth - 1 downto 0);
        else
            return resize(rawVal, dataWidth);
        end if;
    end function;

    pure function updateSand(
        waveVal     : signed(dataWidth - 1 downto 0);
        currSand    : unsigned(15 downto 0)
    ) return unsigned is
        variable magnitude   : unsigned(dataWidth - 1 downto 0);
        variable scaledAmp   : unsigned(16 downto 0);
        variable decayed     : unsigned(16 downto 0);
        variable totalSand   : unsigned(16 downto 0);
    begin
        if waveVal < 0 then
            magnitude := unsigned(-waveVal);
        else
            magnitude := unsigned(waveVal);
        end if;

        scaledAmp := resize(shift_right(magnitude, 8), 17);
        decayed   := resize(currSand, 17) - resize(shift_right(currSand, sandDecayShift), 17);
        totalSand := decayed + scaledAmp;

        if totalSand > 65535 then
            return to_unsigned(65535, 16);
        else
            return totalSand(15 downto 0);
        end if;
    end function;

begin

    solverBusy <= isRunning;

    process(systemClock)

        procedure resetSolver is
        begin
            isRunning     <= '0';
            stepCnt       <= (others => '0');
            latchedSample <= (others => '0');
            validS1       <= '0';
            validS2A      <= '0';
            validS2B      <= '0';
            validS3       <= '0';
        end procedure;

        procedure waitForSample is
        begin
            validS1  <= '0';
            validS2A <= '0';
            validS2B <= '0';
            validS3  <= '0';

            if sampleValid = '1' then
                latchedSample <= audioSampleIn;
                stepCnt       <= (others => '0');
                isRunning     <= '1';
            end if;
        end procedure;

        procedure stage0ReadAddresses is
            variable readY      : unsigned(gridBits + 1 downto 0);
            variable readX      : unsigned(gridBits - 1 downto 0);
            variable centerStep : unsigned((2 * gridBits) + 1 downto 0);
        begin
            readY := stepCnt((2 * gridBits) + 1 downto gridBits);
            readX := stepCnt(gridBits - 1 downto 0);

            if readY < gridSize then
                currReadAddr <= readY(gridBits - 1 downto 0) & readX;
                validS1      <= '1';
            else
                validS1      <= '0';
            end if;
            xS1 <= readX;

            if (stepCnt >= gridSize + 2) and (stepCnt < totalCells + gridSize + 2) then
                centerStep   := stepCnt - to_unsigned(gridSize + 2, stepCnt'length);
                prevReadAddr <= centerStep((2 * gridBits) - 1 downto gridBits) & centerStep(gridBits - 1 downto 0);
            end if;

            if (stepCnt >= gridSize + 3) and (stepCnt < totalCells + gridSize + 3) then
                centerStep := stepCnt - to_unsigned(gridSize + 3, stepCnt'length);
                validS2A   <= '1';
                yS2A       <= centerStep((2 * gridBits) - 1 downto gridBits);
                xS2A       <= centerStep(gridBits - 1 downto 0);
            else
                validS2A   <= '0';
            end if;
        end procedure;

        procedure stage1ShiftWindow is
            variable cellIn   : signed(dataWidth - 1 downto 0);
            variable lowerOut : signed(dataWidth - 1 downto 0);
            variable upperOut : signed(dataWidth - 1 downto 0);
        begin
            if validS1 = '1' then
                cellIn := currWaveRead;
            else
                cellIn := (others => '0');
            end if;

            lowerOut := lowerLineBuf(to_integer(xS1));
            upperOut := upperLineBuf(to_integer(xS1));

            lowerLineBuf(to_integer(xS1)) <= cellIn;
            upperLineBuf(to_integer(xS1)) <= lowerOut;

            for rowIdx in 0 to 2 loop
                for colIdx in 0 to 1 loop
                    window3x3(rowIdx)(colIdx) <= window3x3(rowIdx)(colIdx + 1);
                end loop;
            end loop;

            window3x3(2)(2) <= cellIn;
            window3x3(1)(2) <= lowerOut;
            window3x3(0)(2) <= upperOut;
        end procedure;

        procedure stage2AWavePhysics is
            variable exciteOn : boolean;
        begin
            exciteOn    := isExciteCenter(xS2A, yS2A);
            rawWaveS2B  <= solveWave(window3x3, prevWaveRead, latchedSample, exciteOn);
            currWaveS2B <= window3x3(1)(1);
            sandReadS2B <= sandRead;
            validS2B    <= validS2A;
            xS2B        <= xS2A;
            yS2B        <= yS2A;
        end procedure;

        procedure stage2BBoundaryAndSand is
            variable onBorder    : boolean;
            variable clampedWave : signed(dataWidth - 1 downto 0);
        begin
            onBorder    := isBorder(xS2B, yS2B);
            clampedWave := clampWave(rawWaveS2B, onBorder);
            nextWaveS3  <= clampedWave;
            nextSandS3  <= updateSand(clampedWave, sandReadS2B);
            currWaveS3  <= currWaveS2B;
            validS3     <= validS2B;
            xS3         <= xS2B;
            yS3         <= yS2B;
        end procedure;

        procedure stage3WriteBack is
            variable wrAddr : integer range 0 to totalCells - 1;
        begin
            if validS3 = '1' then
                wrAddr                := to_integer(yS3 & xS3);
                currWaveRam(wrAddr)   <= nextWaveS3;
                prevWaveRam(wrAddr)   <= currWaveS3;
                sandSolverRam(wrAddr) <= nextSandS3;
                sandVgaRam(wrAddr)    <= nextSandS3;
            end if;

            if stepCnt = totalSteps - 1 then
                isRunning <= '0';
            else
                stepCnt <= stepCnt + 1;
            end if;
        end procedure;

    begin
        if rising_edge(systemClock) then
            if syncReset = '1' then
                resetSolver;
            else
                currWaveRead  <= currWaveRam(to_integer(currReadAddr));
                prevWaveRead  <= prevWaveRam(to_integer(prevReadAddr));
                sandRead      <= sandSolverRam(to_integer(prevReadAddr));
                sandAmplitude <= sandVgaRam(to_integer(vgaGridY & vgaGridX));

                if isRunning = '0' then
                    waitForSample;
                else
                    -- Set memory read addresses for the grid
                    stage0ReadAddresses;
                    -- Line up the current cell with its top, bottom, left, and right neighbors
                    stage1ShiftWindow;
                    -- Calculate wave physics and center audio force
                    stage2AWavePhysics;
                    -- Keep edges at zero, limit overflow, and update sand
                    stage2BBoundaryAndSand;
                    -- Save new wave and sand values back to memory
                    stage3WriteBack;
                end if;
            end if;
        end if;
    end process;

end architecture behavioral;