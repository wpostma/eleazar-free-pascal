{
 Test all with:
     ./rundiagtests --format=plain --suite=TTestDiagRingBuffer

 Test specific with:
     ./rundiagtests --format=plain --suite=TestPushSingle
     ./rundiagtests --format=plain --suite=TestWrapAround
     ./rundiagtests --format=plain --suite=TestQuerySinceSeq
}
unit TestDiagRingBuffer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  LCLDiagServer;

type

  { TRingPusherThread - helper for concurrency tests }

  TRingPusherThread = class(TThread)
  private
    FRing: TLCLEventRing;
    FThreadIndex: Integer;
    FPushCount: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(ARing: TLCLEventRing; AIndex, ACount: Integer);
  end;

  { TTestDiagRingBuffer }

  TTestDiagRingBuffer = class(TTestCase)
  published
    procedure TestCreateDestroy;
    procedure TestPushSingle;
    procedure TestPushMultiple;
    procedure TestSequenceNumbersMonotonic;
    procedure TestTimestampsNonDecreasing;
    procedure TestWrapAround;
    procedure TestWrapAroundPreservesNewest;
    procedure TestQuerySinceSeqZero;
    procedure TestQuerySinceSeqMid;
    procedure TestQuerySinceSeqBeyondNewest;
    procedure TestQueryMaxLimit;
    procedure TestQueryAfterWrap;
    procedure TestQueryEmptyBuffer;
    procedure TestStatsEmpty;
    procedure TestStatsAfterPush;
    procedure TestStatsAfterWrap;
    procedure TestCapacityOne;
    procedure TestLargePayload;
    procedure TestSpecialCharsInText;
    procedure TestConcurrentPushes;
    procedure TestJSONEscapeBasic;
    procedure TestJSONEscapeControlChars;
    procedure TestExtractJStr;
    procedure TestExtractJInt;
    procedure TestExtractJBool;
  end;

implementation

{ ===== Test Helpers ======================================================== }

function CountEventsInJSON(const AJSON: string): Integer;
var
  P: Integer;
begin
  Result := 0;
  P := 1;
  while P <= Length(AJSON) do begin
    P := Pos('"seq":', AJSON, P);
    if P = 0 then Break;
    Inc(Result);
    Inc(P, 6);
  end;
end;

function ExtractCountField(const AJSON: string): Integer;
begin
  Result := ExtractJInt(AJSON, 'count');
end;

{ ===== TRingPusherThread =================================================== }

constructor TRingPusherThread.Create(ARing: TLCLEventRing;
  AIndex, ACount: Integer);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FRing := ARing;
  FThreadIndex := AIndex;
  FPushCount := ACount;
end;

procedure TRingPusherThread.Execute;
var
  I: Integer;
begin
  for I := 0 to FPushCount - 1 do
    FRing.Push('t' + IntToStr(FThreadIndex) + '_' + IntToStr(I));
end;

{ ===== Ring Buffer Tests =================================================== }

procedure TTestDiagRingBuffer.TestCreateDestroy;
var
  Ring: TLCLEventRing;
begin
  Ring := TLCLEventRing.Create(16);
  try
    AssertNotNull('Ring created', Ring);
    AssertEquals('capacity', 16, Ring.Capacity);
    AssertEquals('count starts at 0', 0, Ring.Count);
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestPushSingle;
var
  Ring: TLCLEventRing;
  JSON: string;
begin
  Ring := TLCLEventRing.Create(16);
  try
    Ring.Push('hello world');
    JSON := Ring.QueryJSON(0, 100);
    AssertEquals('count field', 1, ExtractCountField(JSON));
    AssertTrue('contains text', Pos('hello world', JSON) > 0);
    AssertEquals('ring count', 1, Ring.Count);
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestPushMultiple;
var
  Ring: TLCLEventRing;
  JSON: string;
  I: Integer;
begin
  Ring := TLCLEventRing.Create(64);
  try
    for I := 1 to 10 do
      Ring.Push('event ' + IntToStr(I));
    JSON := Ring.QueryJSON(0, 100);
    AssertEquals('count field', 10, ExtractCountField(JSON));
    AssertEquals('event count', 10, CountEventsInJSON(JSON));
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestSequenceNumbersMonotonic;
var
  Ring: TLCLEventRing;
  JSON: string;
begin
  Ring := TLCLEventRing.Create(16);
  try
    Ring.Push('first');
    Ring.Push('second');
    Ring.Push('third');
    JSON := Ring.QueryJSON(0, 100);
    { seq 1, 2, 3 must appear in order }
    AssertTrue('seq 1 before seq 2',
      Pos('"seq":1', JSON) < Pos('"seq":2', JSON));
    AssertTrue('seq 2 before seq 3',
      Pos('"seq":2', JSON) < Pos('"seq":3', JSON));
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestTimestampsNonDecreasing;
var
  Ring: TLCLEventRing;
  JSON: string;
  P1, P2: Integer;
  TS1, TS2: string;
begin
  Ring := TLCLEventRing.Create(16);
  try
    Ring.Push('first');
    Ring.Push('second');
    JSON := Ring.QueryJSON(0, 100);
    P1 := Pos('"ts":"', JSON);
    AssertTrue('first ts found', P1 > 0);
    TS1 := Copy(JSON, P1 + 6, 23);
    P2 := Pos('"ts":"', JSON, P1 + 6);
    AssertTrue('second ts found', P2 > 0);
    TS2 := Copy(JSON, P2 + 6, 23);
    AssertTrue('timestamps non-decreasing', TS1 <= TS2);
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestWrapAround;
var
  Ring: TLCLEventRing;
  JSON: string;
  I: Integer;
begin
  Ring := TLCLEventRing.Create(4);
  try
    for I := 1 to 7 do
      Ring.Push('ev' + IntToStr(I));
    JSON := Ring.QueryJSON(0, 100);
    AssertEquals('count after wrap', 4, ExtractCountField(JSON));
    { Oldest 3 gone }
    AssertEquals('ev1 gone', 0, Pos('"ev1"', JSON));
    AssertEquals('ev2 gone', 0, Pos('"ev2"', JSON));
    AssertEquals('ev3 gone', 0, Pos('"ev3"', JSON));
    { Newest 4 present }
    AssertTrue('ev4 present', Pos('ev4', JSON) > 0);
    AssertTrue('ev5 present', Pos('ev5', JSON) > 0);
    AssertTrue('ev6 present', Pos('ev6', JSON) > 0);
    AssertTrue('ev7 present', Pos('ev7', JSON) > 0);
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestWrapAroundPreservesNewest;
var
  Ring: TLCLEventRing;
  JSON: string;
  I: Integer;
begin
  Ring := TLCLEventRing.Create(4);
  try
    for I := 1 to 8 do
      Ring.Push('item' + IntToStr(I));
    JSON := Ring.QueryJSON(0, 100);
    AssertEquals('count', 4, ExtractCountField(JSON));
    AssertTrue('item5', Pos('item5', JSON) > 0);
    AssertTrue('item6', Pos('item6', JSON) > 0);
    AssertTrue('item7', Pos('item7', JSON) > 0);
    AssertTrue('item8', Pos('item8', JSON) > 0);
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestQuerySinceSeqZero;
var
  Ring: TLCLEventRing;
  JSON: string;
begin
  Ring := TLCLEventRing.Create(16);
  try
    Ring.Push('a');
    Ring.Push('b');
    Ring.Push('c');
    JSON := Ring.QueryJSON(0, 100);
    AssertEquals('all events returned', 3, ExtractCountField(JSON));
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestQuerySinceSeqMid;
var
  Ring: TLCLEventRing;
  JSON: string;
begin
  Ring := TLCLEventRing.Create(16);
  try
    Ring.Push('a');  { seq 1 }
    Ring.Push('b');  { seq 2 }
    Ring.Push('c');  { seq 3 }
    Ring.Push('d');  { seq 4 }
    JSON := Ring.QueryJSON(2, 100);
    AssertEquals('events since seq 2', 2, ExtractCountField(JSON));
    AssertTrue('has c', Pos('"c"', JSON) > 0);
    AssertTrue('has d', Pos('"d"', JSON) > 0);
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestQuerySinceSeqBeyondNewest;
var
  Ring: TLCLEventRing;
  JSON: string;
begin
  Ring := TLCLEventRing.Create(16);
  try
    Ring.Push('a');
    Ring.Push('b');
    JSON := Ring.QueryJSON(999, 100);
    AssertEquals('no events', 0, ExtractCountField(JSON));
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestQueryMaxLimit;
var
  Ring: TLCLEventRing;
  JSON: string;
  I: Integer;
begin
  Ring := TLCLEventRing.Create(64);
  try
    for I := 1 to 20 do
      Ring.Push('event' + IntToStr(I));
    JSON := Ring.QueryJSON(0, 5);
    AssertEquals('limited to 5', 5, ExtractCountField(JSON));
    { Should be the oldest 5 }
    AssertTrue('has event1', Pos('event1', JSON) > 0);
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestQueryAfterWrap;
var
  Ring: TLCLEventRing;
  JSON: string;
  I: Integer;
begin
  Ring := TLCLEventRing.Create(8);
  try
    for I := 1 to 20 do
      Ring.Push('n' + IntToStr(I));
    { Query since seq 15 returns seq 16..20 = 5 events }
    JSON := Ring.QueryJSON(15, 100);
    AssertEquals('events after wrap query', 5, ExtractCountField(JSON));
    AssertTrue('has n16', Pos('n16', JSON) > 0);
    AssertTrue('has n20', Pos('n20', JSON) > 0);
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestQueryEmptyBuffer;
var
  Ring: TLCLEventRing;
  JSON: string;
begin
  Ring := TLCLEventRing.Create(16);
  try
    JSON := Ring.QueryJSON(0, 100);
    AssertEquals('empty count', 0, ExtractCountField(JSON));
    AssertTrue('empty events array', Pos('"events":[]', JSON) > 0);
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestStatsEmpty;
var
  Ring: TLCLEventRing;
  JSON: string;
begin
  Ring := TLCLEventRing.Create(16);
  try
    JSON := Ring.StatsJSON;
    AssertEquals('total_pushed', 0, ExtractJInt(JSON, 'total_pushed'));
    AssertEquals('buffer_capacity', 16, ExtractJInt(JSON, 'buffer_capacity'));
    AssertEquals('buffer_used', 0, ExtractJInt(JSON, 'buffer_used'));
    AssertEquals('oldest_seq', 0, ExtractJInt(JSON, 'oldest_seq'));
    AssertEquals('newest_seq', 0, ExtractJInt(JSON, 'newest_seq'));
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestStatsAfterPush;
var
  Ring: TLCLEventRing;
  JSON: string;
begin
  Ring := TLCLEventRing.Create(16);
  try
    Ring.Push('a');
    Ring.Push('b');
    Ring.Push('c');
    JSON := Ring.StatsJSON;
    AssertEquals('total_pushed', 3, ExtractJInt(JSON, 'total_pushed'));
    AssertEquals('buffer_used', 3, ExtractJInt(JSON, 'buffer_used'));
    AssertEquals('oldest_seq', 1, ExtractJInt(JSON, 'oldest_seq'));
    AssertEquals('newest_seq', 3, ExtractJInt(JSON, 'newest_seq'));
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestStatsAfterWrap;
var
  Ring: TLCLEventRing;
  JSON: string;
  I: Integer;
begin
  Ring := TLCLEventRing.Create(4);
  try
    for I := 1 to 10 do
      Ring.Push('x');
    JSON := Ring.StatsJSON;
    AssertEquals('total_pushed', 10, ExtractJInt(JSON, 'total_pushed'));
    AssertEquals('buffer_used', 4, ExtractJInt(JSON, 'buffer_used'));
    AssertEquals('oldest_seq', 7, ExtractJInt(JSON, 'oldest_seq'));
    AssertEquals('newest_seq', 10, ExtractJInt(JSON, 'newest_seq'));
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestCapacityOne;
var
  Ring: TLCLEventRing;
  JSON: string;
begin
  Ring := TLCLEventRing.Create(1);
  try
    Ring.Push('first');
    Ring.Push('second');
    Ring.Push('third');
    JSON := Ring.QueryJSON(0, 100);
    AssertEquals('only 1 event', 1, ExtractCountField(JSON));
    AssertTrue('has third', Pos('third', JSON) > 0);
    AssertEquals('no first', 0, Pos('"first"', JSON));

    JSON := Ring.StatsJSON;
    AssertEquals('total_pushed', 3, ExtractJInt(JSON, 'total_pushed'));
    AssertEquals('buffer_used', 1, ExtractJInt(JSON, 'buffer_used'));
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestLargePayload;
var
  Ring: TLCLEventRing;
  JSON, BigText: string;
  I: Integer;
begin
  Ring := TLCLEventRing.Create(4);
  try
    BigText := '';
    for I := 1 to 1000 do
      BigText := BigText + 'ABCDEFGHIJ';
    Ring.Push(BigText);
    JSON := Ring.QueryJSON(0, 100);
    AssertEquals('1 event', 1, ExtractCountField(JSON));
    AssertTrue('contains payload', Pos('ABCDEFGHIJ', JSON) > 0);
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestSpecialCharsInText;
var
  Ring: TLCLEventRing;
  JSON: string;
begin
  Ring := TLCLEventRing.Create(16);
  try
    Ring.Push('line1' + #10 + 'line2');
    Ring.Push('tab' + #9 + 'here');
    Ring.Push('quote"inside');
    Ring.Push('backslash\path');
    JSON := Ring.QueryJSON(0, 100);
    AssertEquals('4 events', 4, ExtractCountField(JSON));
    AssertTrue('escaped newline', Pos('\n', JSON) > 0);
    AssertTrue('escaped tab', Pos('\t', JSON) > 0);
    AssertTrue('escaped quote', Pos('\"', JSON) > 0);
    AssertTrue('escaped backslash', Pos('\\', JSON) > 0);
  finally
    Ring.Free;
  end;
end;

procedure TTestDiagRingBuffer.TestConcurrentPushes;
const
  THREAD_COUNT = 4;
  PUSHES_PER_THREAD = 500;
var
  Ring: TLCLEventRing;
  Threads: array[0..THREAD_COUNT-1] of TRingPusherThread;
  JSON: string;
  I: Integer;
begin
  Ring := TLCLEventRing.Create(THREAD_COUNT * PUSHES_PER_THREAD);
  try
    for I := 0 to THREAD_COUNT - 1 do
      Threads[I] := TRingPusherThread.Create(Ring, I, PUSHES_PER_THREAD);

    for I := 0 to THREAD_COUNT - 1 do begin
      Threads[I].WaitFor;
      Threads[I].Free;
    end;

    JSON := Ring.StatsJSON;
    AssertEquals('total_pushed after concurrent',
      THREAD_COUNT * PUSHES_PER_THREAD,
      ExtractJInt(JSON, 'total_pushed'));
    AssertEquals('buffer_used after concurrent',
      THREAD_COUNT * PUSHES_PER_THREAD,
      ExtractJInt(JSON, 'buffer_used'));
  finally
    Ring.Free;
  end;
end;

{ ===== JSON Helper Tests =================================================== }

procedure TTestDiagRingBuffer.TestJSONEscapeBasic;
begin
  AssertEquals('plain text', 'hello', JSONEscape('hello'));
  AssertEquals('empty', '', JSONEscape(''));
  AssertEquals('quote', 'say \"hi\"', JSONEscape('say "hi"'));
  AssertEquals('backslash', 'a\\b', JSONEscape('a\b'));
end;

procedure TTestDiagRingBuffer.TestJSONEscapeControlChars;
begin
  AssertEquals('newline', 'a\nb', JSONEscape('a' + #10 + 'b'));
  AssertEquals('tab', 'a\tb', JSONEscape('a' + #9 + 'b'));
  AssertEquals('cr', 'a\rb', JSONEscape('a' + #13 + 'b'));
  AssertEquals('backspace', 'a\bb', JSONEscape('a' + #8 + 'b'));
  AssertEquals('formfeed', 'a\fb', JSONEscape('a' + #12 + 'b'));
  AssertEquals('null', 'a\u0000b', JSONEscape('a' + #0 + 'b'));
end;

procedure TTestDiagRingBuffer.TestExtractJStr;
var
  JSON: string;
begin
  JSON := '{"name":"hello","other":"world"}';
  AssertEquals('name', 'hello', ExtractJStr(JSON, 'name'));
  AssertEquals('other', 'world', ExtractJStr(JSON, 'other'));
  AssertEquals('missing', '', ExtractJStr(JSON, 'nope'));
end;

procedure TTestDiagRingBuffer.TestExtractJInt;
var
  JSON: string;
begin
  JSON := '{"count":42,"neg":-7,"zero":0}';
  AssertEquals('count', 42, ExtractJInt(JSON, 'count'));
  AssertEquals('neg', -7, ExtractJInt(JSON, 'neg'));
  AssertEquals('zero', 0, ExtractJInt(JSON, 'zero'));
  AssertEquals('missing', 0, ExtractJInt(JSON, 'nope'));
end;

procedure TTestDiagRingBuffer.TestExtractJBool;
var
  JSON: string;
begin
  JSON := '{"yes":true,"no":false}';
  AssertEquals('yes', True, ExtractJBool(JSON, 'yes'));
  AssertEquals('no', False, ExtractJBool(JSON, 'no'));
  AssertEquals('missing', False, ExtractJBool(JSON, 'nope'));
end;

initialization
  RegisterTest(TTestDiagRingBuffer);

end.
