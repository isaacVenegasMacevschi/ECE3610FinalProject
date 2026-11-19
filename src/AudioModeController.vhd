library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity audioModeController is
    port (
        systemClock    : in  std_logic;
        syncReset      : in  std_logic;
        swMode         : in  std_logic;
        customPhaseInc : in  unsigned(31 downto 0);
        romAddr        : out std_logic_vector(10 downto 0);
        romData        : in  std_logic_vector(23 downto 0);
        audioSample    : out signed(15 downto 0);
        sampleValid    : out std_logic;
        audioPwm       : out std_logic
    );
end entity audioModeController;

architecture behavioral of audioModeController is

    constant clksPerSample : integer := 2048;
    constant clksPerMs     : integer := 120000;
    constant songStartAddr : unsigned(10 downto 0) := to_unsigned(0, 11);
    constant songEndAddr   : unsigned(10 downto 0) := to_unsigned(95, 11);

    -- Lookup table that turns each MIDI note (0 to 127) into a pitch speed (0 = silent rest)
    type midiIncLutArray is array (0 to 127) of unsigned(31 downto 0);
    constant midiIncLut : midiIncLutArray := (
        x"00000000", x"000BA03A", x"000C5134", x"000D0CB3", x"000DD359", x"000EA5CF", x"000F84C9", x"00107105",
        x"00116B4D", x"00127477", x"00138D65", x"0014B708", x"0015F25E", x"00174074", x"0018A267", x"001A1967",
        x"001BA6B3", x"001D4B9F", x"001F0992", x"0020E20A", x"0022D69A", x"0024E8EE", x"00271ACA", x"00296E10",
        x"002BE4BC", x"002E80E7", x"003144CE", x"003432CD", x"00374D65", x"003A973D", x"003E1324", x"0041C413",
        x"0045AD33", x"0049D1DB", x"004E3595", x"0052DC20", x"0057C977", x"005D01CF", x"0062899D", x"0068659B",
        x"006E9ACB", x"00752E7A", x"007C2647", x"00838827", x"008B5A67", x"0093A3B6", x"009C6B2A", x"00A5B841",
        x"00AF92EE", x"00BA039D", x"00C51339", x"00D0CB35", x"00DD3595", x"00EA5CF4", x"00F84C8F", x"0107104E",
        x"0116B4CE", x"0127476D", x"0138D653", x"014B7081", x"015F25DC", x"0174073A", x"018A2672", x"01A1966B",
        x"01BA6B2B", x"01D4B9E8", x"01F0991E", x"020E209B", x"022D699C", x"024E8ED9", x"0271ACA6", x"0296E103",
        x"02BE4BB8", x"02E80E74", x"03144CE4", x"03432CD6", x"0374D655", x"03A973D0", x"03E1323B", x"041C4136",
        x"045AD337", x"049D1DB3", x"04E3594C", x"052DC205", x"057C9770", x"05D01CE8", x"062899C9", x"068659AC",
        x"06E9ACAA", x"0752E7A0", x"07C26476", x"0838826D", x"08B5A66E", x"093A3B65", x"09C6B298", x"0A5B840A",
        x"0AF92EE1", x"0BA039D0", x"0C513391", x"0D0CB357", x"0DD35954", x"0EA5CF41", x"0F84C8ED", x"107104DA",
        x"116B4CDC", x"127476CA", x"138D6531", x"14B70815", x"15F25DC1", x"174073A1", x"18A26723", x"1A1966AE",
        x"1BA6B2A9", x"1D4B9E82", x"1F0991DA", x"20E209B3", x"22D699B8", x"24E8ED95", x"271ACA62", x"296E102A",
        x"2BE4BB83", x"2E80E742", x"3144CE45", x"3432CD5D", x"374D6551", x"3A973D03", x"3E1323B3", x"41C41366"
    );

    -- 64-point sound wave shape that gives the synth its saxophone tone
    type waveLutArray is array (0 to 63) of integer range -32768 to 32767;
    constant saxLut : waveLutArray := (
           0,   6400,  12800,  18500,  24000,  29000,  32000,  30500,
       28000,  25000,  22000,  19000,  16000,  13500,  11000,   9000,
        7500,   6000,   4800,   3600,   2500,   1500,    600,      0,
        -500,  -1000,  -1500,  -2000,  -2500,  -3000,  -3500,  -4000,
       -4500,  -5200,  -6000,  -7000,  -8200,  -9500, -11000, -12800,
      -14800, -17000, -19500, -22000, -24500, -27000, -29000, -31000,
      -32767, -31500, -29000, -25500, -21500, -17500, -13500, -10000,
       -7000,  -4500,  -2500,  -1200,   -500,   -200,   -100,      0
    );

    type delayRamArray is array (0 to 4095) of signed(15 downto 0);
    signal delayRam     : delayRamArray := (others => (others => '0'));
    signal delayPtr     : unsigned(11 downto 0) := (others => '0');
    signal delayOut     : signed(15 downto 0) := (others => '0');
    
    signal seqState     : integer range 0 to 2 := 0;
    signal romAddrReg   : unsigned(10 downto 0) := songStartAddr;
    signal waitCnt      : unsigned(1 downto 0) := (others => '0');
    signal midiNote     : integer range 0 to 127 := 0;
    signal noteLeftMs   : unsigned(15 downto 0) := (others => '0');
    signal noteAgeMs    : unsigned(15 downto 0) := (others => '0');
    signal msClkCnt     : integer range 0 to clksPerMs - 1 := 0;
    signal envGain      : unsigned(8 downto 0) := (others => '0');
    signal vibPhase     : unsigned(15 downto 0) := (others => '0');

    signal sampleCnt    : integer range 0 to clksPerSample - 1 := 0;
    signal solverToggle : std_logic := '0';
    signal phaseAcc     : unsigned(31 downto 0) := (others => '0');
    signal filt1        : signed(17 downto 0) := (others => '0');
    signal filt2        : signed(17 downto 0) := (others => '0');

    signal pwmCnt       : unsigned(7 downto 0) := (others => '0');
    signal pwmDuty      : unsigned(7 downto 0) := to_unsigned(128, 8);

    pure function updateGain(
        note     : integer range 0 to 127;
        leftMs   : unsigned(15 downto 0);
        ageMs    : unsigned(15 downto 0);
        gain     : unsigned(8 downto 0)
    ) return unsigned is
    begin
        if note = 0 then
            return to_unsigned(0, 9);
        elsif leftMs <= 45 then
            if gain > 20 then
                return gain - 20;
            else
                return to_unsigned(0, 9);
            end if;
        elsif ageMs < 16 then
            if gain + 14 >= 256 then
                return to_unsigned(256, 9);
            else
                return gain + 14;
            end if;
        elsif (ageMs(3 downto 0) = "0000") and (gain > 205) then
            return gain - 1;
        else
            return gain;
        end if;
    end function;

    pure function stepPhase(
        phase    : unsigned(31 downto 0);
        inc      : unsigned(31 downto 0);
        vibAngle : unsigned(15 downto 0);
        vibOn    : boolean
    ) return unsigned is
        variable tri       : signed(8 downto 0);
        variable vibStep   : signed(18 downto 0);
        variable vibDelta  : signed(27 downto 0);
        variable nextPhase : signed(32 downto 0);
    begin
        if vibOn then
            if vibAngle(15) = '0' then
                tri := signed('0' & vibAngle(14 downto 7)) - to_signed(128, 9);
            else
                tri := to_signed(127, 9) - signed('0' & vibAngle(14 downto 7));
            end if;
            vibStep   := signed(resize(shift_right(inc, 15), 19));
            vibDelta  := vibStep * tri;
            nextPhase := signed('0' & phase) + signed('0' & inc) + resize(vibDelta, 33);
            return unsigned(nextPhase(31 downto 0));
        else
            return phase + inc;
        end if;
    end function;

    pure function getSaxSample(
        phase : unsigned(31 downto 0);
        gain  : unsigned(8 downto 0)
    ) return signed is
        variable idx0   : integer range 0 to 63;
        variable idx1   : integer range 0 to 63;
        variable diff   : signed(15 downto 0);
        variable frac   : signed(8 downto 0);
        variable interp : signed(15 downto 0);
        variable prod   : signed(25 downto 0);
    begin
        idx0 := to_integer(phase(31 downto 26));
        if idx0 = 63 then
            idx1 := 0;
        else
            idx1 := idx0 + 1;
        end if;

        diff   := to_signed(saxLut(idx1) - saxLut(idx0), 16);
        frac   := signed('0' & phase(25 downto 18));
        interp := to_signed(saxLut(idx0), 16) + resize(shift_right(diff * frac, 8), 16);
        prod   := interp * signed('0' & gain);
        return resize(shift_right(prod, 8), 16);
    end function;

    pure function clamp16(val : signed(17 downto 0)) return signed is
    begin
        if val > 32767 then
            return to_signed(32767, 16);
        elsif val < -32768 then
            return to_signed(-32768, 16);
        else
            return resize(val, 16);
        end if;
    end function;

    pure function scaleSolverOut(wet : signed(17 downto 0)) return signed is
        variable boost : signed(18 downto 0);
    begin
        boost := resize(wet, 19) + shift_right(resize(wet, 19), 1);
        if boost > 16000 then
            return to_signed(16000, 16);
        elsif boost < -16000 then
            return to_signed(-16000, 16);
        else
            return resize(boost, 16);
        end if;
    end function;

    pure function getPwmDuty(wet : signed(17 downto 0)) return unsigned is
        variable boost   : signed(19 downto 0);
        variable clamped : signed(15 downto 0);
    begin
        boost := resize(wet, 20) + shift_right(resize(wet, 20), 1);
        if boost > 15000 then
            clamped := to_signed(15000, 16);
        elsif boost < -15000 then
            clamped := to_signed(-15000, 16);
        else
            clamped := resize(boost, 16);
        end if;
        return unsigned(not clamped(15) & clamped(14 downto 8));
    end function;

begin

    romAddr <= std_logic_vector(romAddrReg);

    -- Read notes from the song memory and fade volume smoothly
    process(systemClock)

        procedure resetSeq is
        begin
            seqState   <= 0;
            romAddrReg <= songStartAddr;
            waitCnt    <= (others => '0');
            midiNote   <= 0;
            noteLeftMs <= (others => '0');
            noteAgeMs  <= (others => '0');
            msClkCnt   <= 0;
            envGain    <= (others => '0');
            vibPhase   <= (others => '0');
        end procedure;

        procedure fetchNote is
        begin
            waitCnt  <= (others => '0');
            seqState <= 1;
        end procedure;

        procedure loadNote is
        begin
            if waitCnt = "10" then
                midiNote   <= to_integer(unsigned(romData(22 downto 16)));
                noteLeftMs <= unsigned(romData(15 downto 0));
                noteAgeMs  <= (others => '0');
                msClkCnt   <= 0;
                vibPhase   <= (others => '0');
                envGain    <= (others => '0');
                seqState   <= 2;
            else
                waitCnt <= waitCnt + 1;
            end if;
        end procedure;

        procedure playNote is
        begin
            if noteLeftMs = 0 then
                if romAddrReg >= songEndAddr then
                    romAddrReg <= songStartAddr;
                else
                    romAddrReg <= romAddrReg + 1;
                end if;
                seqState <= 0;
            elsif msClkCnt = clksPerMs - 1 then
                msClkCnt   <= 0;
                noteLeftMs <= noteLeftMs - 1;
                noteAgeMs  <= noteAgeMs + 1;
                vibPhase   <= vibPhase + to_unsigned(380, 16);
                envGain    <= updateGain(midiNote, noteLeftMs, noteAgeMs, envGain);
            else
                msClkCnt <= msClkCnt + 1;
            end if;
        end procedure;

    begin
        if rising_edge(systemClock) then
            if syncReset = '1' then
                resetSeq;
            else
                case seqState is
                    when 0 =>
                        -- Ask song memory for the next note
                        fetchNote;
                    when 1 =>
                        -- Wait for memory and save the note pitch and length
                        loadNote;
                    when others =>
                        -- Count down note time and adjust volume fade
                        playNote;
                end case;
            end if;
        end if;
    end process;

    -- Create saxophone sound, smooth it, add echo, and send it out
    process(systemClock)

        procedure resetDsp is
        begin
            sampleCnt    <= 0;
            solverToggle <= '0';
            phaseAcc     <= (others => '0');
            filt1        <= (others => '0');
            filt2        <= (others => '0');
            audioSample  <= (others => '0');
            delayPtr     <= (others => '0');
            delayOut     <= (others => '0');
            pwmDuty      <= to_unsigned(128, 8);
            sampleValid  <= '0';
        end procedure;

        procedure runAudioDsp is
            variable inc    : unsigned(31 downto 0);
            variable gain   : unsigned(8 downto 0);
            variable vibOn  : boolean;
            variable raw    : signed(15 downto 0);
            variable nextF1 : signed(17 downto 0);
            variable nextF2 : signed(17 downto 0);
            variable echo   : signed(17 downto 0);
            variable wet    : signed(17 downto 0);
        begin
            -- Choose pitch from either serial input (swMode = '1') or song memory (swMode = '0')
            if swMode = '1' then
                inc := customPhaseInc;
                if customPhaseInc = 0 then
                    gain := (others => '0');
                else
                    gain := to_unsigned(256, 9);
                end if;
            else
                if midiNote = 0 then
                    inc := (others => '0');
                else
                    inc := midiIncLut(midiNote);
                end if;
                gain := envGain;
            end if;

            -- Step through the saxophone wave table to generate the raw sound
            if inc = 0 then
                raw := (others => '0');
            else
                vibOn    := (swMode = '0') and (noteAgeMs > 180);
                phaseAcc <= stepPhase(phaseAcc, inc, vibPhase, vibOn);
                raw      := getSaxSample(phaseAcc, gain);
            end if;

            -- Smooth harsh edges with a low-pass filter and mix in a light echo
            nextF1 := filt1 + shift_right(resize(raw, 18) - filt1, 2);
            nextF2 := filt2 + shift_right(nextF1 - filt2, 2);
            filt1  <= nextF1;
            filt2  <= nextF2;

            echo := shift_right(resize(delayOut, 18), 4);
            delayRam(to_integer(delayPtr)) <= clamp16(nextF2 + echo);
            delayPtr <= delayPtr + 1;
            wet      := nextF2 + echo;

            -- Send sound sample to the wave simulator and update speaker volume duty
            if solverToggle = '0' then
                audioSample <= scaleSolverOut(wet);
                sampleValid <= '1';
            end if;
            solverToggle <= not solverToggle;
            pwmDuty      <= getPwmDuty(wet);
        end procedure;

    begin
        if rising_edge(systemClock) then
            if syncReset = '1' then
                resetDsp;
            else
                sampleValid <= '0';

                if sampleCnt = 0 then
                    runAudioDsp;
                    sampleCnt <= sampleCnt + 1;
                elsif sampleCnt = 1 then
                    delayOut  <= delayRam(to_integer(delayPtr));
                    sampleCnt <= sampleCnt + 1;
                elsif sampleCnt = clksPerSample - 1 then
                    sampleCnt <= 0;
                else
                    sampleCnt <= sampleCnt + 1;
                end if;
            end if;
        end if;
    end process;

    -- Convert the audio level into fast on/off pulses for the speaker pin
    process(systemClock)

        procedure drivePwm is
        begin
            pwmCnt <= pwmCnt + 1;
            if pwmCnt < pwmDuty then
                audioPwm <= '1';
            else
                audioPwm <= '0';
            end if;
        end procedure;

    begin
        if rising_edge(systemClock) then
            if syncReset = '1' then
                pwmCnt   <= (others => '0');
                audioPwm <= '0';
            else
                drivePwm;
            end if;
        end if;
    end process;

end architecture behavioral;