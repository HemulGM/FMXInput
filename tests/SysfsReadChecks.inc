// Exercise the exact sysfs reader on a non-seekable stream with a false size.
type
  TSysfsTestStream = class(TStream)
  private
    FBytes: TBytes;
    FOffset, FChunkSize: Integer;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(const Text: string; ChunkSize: Integer);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

constructor TSysfsTestStream.Create(const Text: string; ChunkSize: Integer);
begin inherited Create; FBytes := TEncoding.UTF8.GetBytes(Text); FChunkSize := ChunkSize; end;
function TSysfsTestStream.GetSize: Int64;
begin Result := 4096; end;
function TSysfsTestStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := Length(FBytes) - FOffset;
  if Result > Count then Result := Count;
  if Result > FChunkSize then Result := FChunkSize;
  if Result > 0 then begin Move(FBytes[FOffset], Buffer, Result); Inc(FOffset, Result); end;
end;
function TSysfsTestStream.Write(const Buffer; Count: Longint): Longint;
begin raise EInvalidOperation.Create('Read-only sysfs attribute'); end;
function TSysfsTestStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin raise EInvalidOperation.Create('Sysfs reader must not seek'); end;

{$I ../FMXInput.SysfsRead.inc}

procedure TestSysfsReads;
begin
  var Stream := TSysfsTestStream.Create('AGK700' + #10, 4096);
  try
    var Buffer: TBytes;
    SetLength(Buffer, Stream.Size);
    var Failed := False;
    try Stream.ReadBuffer(Buffer, Length(Buffer)); except on E: EReadError do Failed := True; end;
    Check(Failed, 'Reproduce old size-based read failure');
  finally Stream.Free; end;
  Stream := TSysfsTestStream.Create('AGK700' + #10, 4096);
  try Check(ReadSysfsText(Stream) = 'AGK700', 'Sysfs nominal size must not dictate read length');
  finally Stream.Free; end;
  Stream := TSysfsTestStream.Create('Клавиатура' + #10, 1);
  try Check(ReadSysfsText(Stream) = 'Клавиатура', 'Partial reads preserve UTF-8');
  finally Stream.Free; end;
  Stream := TSysfsTestStream.Create('', 4096);
  try Check(ReadSysfsText(Stream) = '', 'Empty optional attribute');
  finally Stream.Free; end;
  Stream := TSysfsTestStream.Create(StringOfChar('x', 4096), 4096);
  try Check(Length(ReadSysfsText(Stream)) = 4096, 'Full chunk followed by EOF');
  finally Stream.Free; end;
end;
