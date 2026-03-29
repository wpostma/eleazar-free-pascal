unit aunit2;

{$mode ObjFPC}{$H+}



interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, SynEdit;

type

  { TForm2 }

  TForm2 = class(TForm)
    Button1: TButton;
    Edit1: TEdit;
    Label1: TLabel;
    SynEdit1: TSynEdit;
    procedure Button1Click(Sender: TObject);
  private

  public

  end;

var
  Form2: TForm2;

implementation

{$R *.lfm}

{ TForm2 }

procedure TForm2.Button1Click(Sender: TObject);
begin

  Self.DebugLogging:= true;

  Button1.DebugLogging:=  true;

  ShowMessage( Edit1.Text+' you are awesome!');

end;

end.

