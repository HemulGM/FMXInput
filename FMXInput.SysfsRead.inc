// sysfs reports a nominal file size, not the length of the generated attribute.
// Do not use Stream.Size, Seek or ReadBuffer here. Short reads are valid.
function ReadSysfsText(Stream: TStream): string;
const
  MaxAttributeBytes = 65536;
var
  Chunk: array[0..4095] of Byte;
begin
  var Data := TMemoryStream.Create;
  try
    while True do
    begin
      var Count := Stream.Read(Chunk, SizeOf(Chunk));
      if Count < 0 then raise EReadError.Create('Cannot read sysfs attribute');
      if Count = 0 then Break;
      if Data.Size + Count > MaxAttributeBytes then
        raise EReadError.Create('Sysfs attribute exceeds the read limit');
      Data.WriteBuffer(Chunk, Count);
    end;
    var Bytes: TBytes;
    SetLength(Bytes, Data.Size);
    if Length(Bytes) > 0 then Move(Data.Memory^, Bytes[0], Length(Bytes));
    Result := TEncoding.UTF8.GetString(Bytes).Trim;
  finally Data.Free; end;
end;
