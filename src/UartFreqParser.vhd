library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uartFreqParser is
    port (
        systemClock : in  std_logic;
        syncReset   : in  std_logic;
        swMode      : in  std_logic;
        rxPin       : in  std_logic;
        txPin       : out std_logic;
        phaseInc    : out unsigned(31 downto 0)
    );
end entity uartFreqParser;

architecture behavioral of uartFreqParser is

    constant clksPerBit      : integer := 10416;
    constant freqToPhaseMult : unsigned(31 downto 0) := to_unsigned(87961, 32);

    signal rxState    : integer range 0 to 3 := 0;
    signal rxSync1    : std_logic := '1';
    signal rxSync2    : std_logic := '1';
    signal rxClkCnt   : integer range 0 to clksPerBit - 1 := 0;
    signal rxBitIdx   : integer range 0 to 7 := 0;
    signal rxByte     : std_logic_vector(7 downto 0) := (others => '0');

    signal typedFreq  : unsigned(31 downto 0) := (others => '0');
    signal hasDigits  : std_logic := '0';
    signal phaseOut   : unsigned(31 downto 0) := (others => '0');
    signal prevSwMode : std_logic := '0';

    signal txState    : integer range 0 to 3 := 0;
    signal txClkCnt   : integer range 0 to clksPerBit - 1 := 0;
    signal txBitIdx   : integer range 0 to 7 := 0;
    signal txShift    : std_logic_vector(7 downto 0) := (others => '1');
    signal txStartReq : std_logic := '0';
    signal txByte     : std_logic_vector(7 downto 0) := (others => '0');
    signal txBusy     : std_logic := '0';

    signal msgState   : integer range 0 to 4 := 1;
    signal msgIdx     : integer range 0 to 63 := 0;
    signal echoByte   : std_logic_vector(7 downto 0) := (others => '0');

    constant promptLen : integer := 36;
    type promptArray is array (0 to promptLen - 1) of character;
    constant promptText : promptArray := (
        CR, LF,
        'E','n','t','e','r',' ','f','r','e','q','u','e','n','c','y',' ',
        '(','2','0','0',' ','-',' ','2','0','0','0','0',' ','H','z',')',':',' '
    );

    constant validLen : integer := 16;
    type validArray is array (0 to validLen - 1) of character;
    constant validText : validArray := (
        CR, LF, '[','O','K',']',' ','U','p','d','a','t','e','d','!',' '
    );

    constant invalidLen : integer := 29;
    type invalidArray is array (0 to invalidLen - 1) of character;
    constant invalidText : invalidArray := (
        CR, LF, '[','E','R','R',']',' ','R','a','n','g','e',':',' ',
        '2','0','0',' ','-',' ','2','0','0','0','0',' ','H','z'
    );

    pure function charToByte(ch : character) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(character'pos(ch), 8));
    end function;

    pure function isEnterKey(byteVal : std_logic_vector(7 downto 0)) return boolean is
    begin
        return (byteVal = x"0D") or (byteVal = x"0A");
    end function;

    pure function isBackspaceKey(byteVal : std_logic_vector(7 downto 0)) return boolean is
    begin
        return (byteVal = x"08") or (byteVal = x"7F");
    end function;

    pure function isDigitByte(byteVal : std_logic_vector(7 downto 0)) return boolean is
        variable code : unsigned(7 downto 0);
    begin
        code := unsigned(byteVal);
        return (code >= 48) and (code <= 57);
    end function;

    pure function appendDigit(
        currVal : unsigned(31 downto 0);
        byteVal : std_logic_vector(7 downto 0)
    ) return unsigned is
        variable digit : unsigned(31 downto 0);
    begin
        digit := resize(unsigned(byteVal) - 48, 32);
        return resize((currVal * 10) + digit, 32);
    end function;

    pure function dropLastDigit(currVal : unsigned(31 downto 0)) return unsigned is
    begin
        return currVal / 10;
    end function;

    pure function freqToPhase(freqHz : unsigned(31 downto 0)) return unsigned is
    begin
        return resize(freqHz * freqToPhaseMult, 32);
    end function;

begin

    phaseInc <= phaseOut;

    process(systemClock)

        procedure resetParser is
        begin
            rxState    <= 0;
            rxClkCnt   <= 0;
            rxBitIdx   <= 0;
            typedFreq  <= (others => '0');
            hasDigits  <= '0';
            phaseOut   <= (others => '0');
            txState    <= 0;
            txClkCnt   <= 0;
            txBitIdx   <= 0;
            txPin      <= '1';
            txBusy     <= '0';
            msgState   <= 1;
            msgIdx     <= 0;
        end procedure;

        -- Check each typed character thus Enter submits, Backspace deletes, 0-9 gens the number
        procedure parseTypedByte is
        begin
            if isEnterKey(rxByte) then
                if hasDigits = '1' then
                    if (typedFreq >= 200) and (typedFreq <= 20000) then
                        phaseOut <= freqToPhase(typedFreq);
                        msgState <= 2;
                        msgIdx   <= 0;
                    else
                        msgState <= 3;
                        msgIdx   <= 0;
                    end if;
                    typedFreq <= (others => '0');
                    hasDigits <= '0';
                end if;
            elsif isBackspaceKey(rxByte) then
                typedFreq <= dropLastDigit(typedFreq);
                echoByte  <= x"08";
                msgState  <= 4;
            elsif isDigitByte(rxByte) then
                if typedFreq <= 99999 then
                    typedFreq <= appendDigit(typedFreq, rxByte);
                    hasDigits <= '1';
                    echoByte  <= rxByte;
                    msgState  <= 4;
                end if;
            end if;
        end procedure;

        procedure receiveUartByte is
        begin
            case rxState is
                when 0 =>
                    -- Wait for the serial line to drop low (start bit)
                    rxClkCnt <= 0;
                    if rxSync2 = '0' then
                        rxState <= 1;
                    end if;

                when 1 =>
                    -- Check halfway through the start bit to make sure it is real
                    if rxClkCnt = (clksPerBit / 2) - 1 then
                        if rxSync2 = '0' then
                            rxClkCnt <= 0;
                            rxBitIdx <= 0;
                            rxState  <= 2;
                        else
                            rxState <= 0;
                        end if;
                    else
                        rxClkCnt <= rxClkCnt + 1;
                    end if;

                when 2 =>
                    -- Sample all 8 data bits one by one
                    if rxClkCnt = clksPerBit - 1 then
                        rxClkCnt         <= 0;
                        rxByte(rxBitIdx) <= rxSync2;
                        if rxBitIdx = 7 then
                            rxState <= 3;
                        else
                            rxBitIdx <= rxBitIdx + 1;
                        end if;
                    else
                        rxClkCnt <= rxClkCnt + 1;
                    end if;

                when others =>
                    -- Finish the stop bit and process the received character
                    if rxClkCnt = clksPerBit - 1 then
                        rxClkCnt <= 0;
                        rxState  <= 0;
                        parseTypedByte;
                    else
                        rxClkCnt <= rxClkCnt + 1;
                    end if;
            end case;
        end procedure;

        procedure sendReplyMessage is
        begin
            if (txBusy = '0') and (txStartReq = '0') then
                case msgState is
                    when 4 =>
                        -- Echo the typed digit or backspace back to the screen
                        txByte     <= echoByte;
                        txStartReq <= '1';
                        msgState   <= 0;

                    when 1 =>
                        -- Print the frequency prompt message
                        if msgIdx < promptLen then
                            txByte     <= charToByte(promptText(msgIdx));
                            txStartReq <= '1';
                            msgIdx     <= msgIdx + 1;
                        else
                            msgState <= 0;
                            msgIdx   <= 0;
                        end if;

                    when 2 =>
                        -- Print [OK] confirmation, then show a new prompt
                        if msgIdx < validLen then
                            txByte     <= charToByte(validText(msgIdx));
                            txStartReq <= '1';
                            msgIdx     <= msgIdx + 1;
                        else
                            msgState <= 1;
                            msgIdx   <= 0;
                        end if;

                    when 3 =>
                        -- Print out of range error, then show a new prompt
                        if msgIdx < invalidLen then
                            txByte     <= charToByte(invalidText(msgIdx));
                            txStartReq <= '1';
                            msgIdx     <= msgIdx + 1;
                        else
                            msgState <= 1;
                            msgIdx   <= 0;
                        end if;

                    when others =>
                        null;
                end case;
            end if;
        end procedure;

        procedure transmitUartByte is
        begin
            case txState is
                when 0 =>
                    -- Keep line high while waiting for a byte to send
                    txPin <= '1';
                    if txStartReq = '1' then
                        txShift  <= txByte;
                        txClkCnt <= 0;
                        txBusy   <= '1';
                        txState  <= 1;
                    else
                        txBusy <= '0';
                    end if;

                when 1 =>
                    -- Send low start bit
                    txPin <= '0';
                    if txClkCnt = clksPerBit - 1 then
                        txClkCnt <= 0;
                        txBitIdx <= 0;
                        txState  <= 2;
                    else
                        txClkCnt <= txClkCnt + 1;
                    end if;

                when 2 =>
                    -- Send each of the 8 data bits
                    txPin <= txShift(txBitIdx);
                    if txClkCnt = clksPerBit - 1 then
                        txClkCnt <= 0;
                        if txBitIdx = 7 then
                            txState <= 3;
                        else
                            txBitIdx <= txBitIdx + 1;
                        end if;
                    else
                        txClkCnt <= txClkCnt + 1;
                    end if;

                when others =>
                    -- Send high stop bit and return to idle
                    txPin <= '1';
                    if txClkCnt = clksPerBit - 1 then
                        txClkCnt <= 0;
                        txBusy   <= '0';
                        txState  <= 0;
                    else
                        txClkCnt <= txClkCnt + 1;
                    end if;
            end case;
        end procedure;

    begin
        if rising_edge(systemClock) then
            -- Synchronize incoming serial pin to prevent metastability
            rxSync1    <= rxPin;
            rxSync2    <= rxSync1;
            prevSwMode <= swMode;
            txStartReq <= '0';

            if syncReset = '1' then
                resetParser;
            else
                -- Show a fresh prompt whenever the mode switch turns ON
                if (prevSwMode = '0') and (swMode = '1') then
                    msgState  <= 1;
                    msgIdx    <= 0;
                    typedFreq <= (others => '0');
                    hasDigits <= '0';
                end if;

                receiveUartByte;
                sendReplyMessage;
                transmitUartByte;
            end if;
        end if;
    end process;

end architecture behavioral;