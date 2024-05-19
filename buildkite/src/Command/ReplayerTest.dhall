let B = ../External/Buildkite.dhall

let Prelude = ../External/Prelude.dhall
let Artifacts = ../Constants/Artifacts.dhall
let Command = ./Base.dhall
let Docker = ./Docker/Type.dhall
let Size = ./Size.dhall
let RunWithPostgres = ./RunWithPostgres.dhall

let B/SoftFail = B.definitions/commandStep/properties/soft_fail/Type

let Cmd = ../Lib/Cmds.dhall in

{ step = \(dependsOn : List Command.TaggedKey.Type) ->
    Command.build
      Command.Config::{
        commands = [
        RunWithPostgres.runInDockerWithPostgresConn
          ([] : List Text)
           "./src/app/replayer/test/archive/sample_db/archive_db.sql"
           Artifacts.Type.Archive 
           "./scripts/replayer-test.sh -d /workdir/src/app/replayer/ -a mina-replayer -p $PG_CONN"
        ],
        label = "Archive: Replayer test",
        key = "replayer-test",
        target = Size.Large,
        depends_on = dependsOn
      }
}
