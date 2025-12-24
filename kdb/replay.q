/ replay.q - Replay TP log to RTE

.replay.cfg.port:5012;
.replay.cfg.logDir:"logs";
.replay.cfg.msgLen:145;

args:.Q.opt .z.x;
if[`port in key args; .replay.cfg.port:"J"$first args`port];

.replay.parseLog:{[bytes]
  n:count[bytes] div .replay.cfg.msgLen;
  hdr:0x0100000099000000;
  msgs:{[hdr;bytes;i] -9!hdr,bytes[(.replay.cfg.msgLen*i)+til .replay.cfg.msgLen]}[hdr;bytes] each til n;
  msgs
  };

.replay.run:{[]
  -1 "Connecting to port ",string .replay.cfg.port;
  h:@[hopen; `$"::",string .replay.cfg.port; {-1 "Failed: ",x; 0N}];
  if[null h; '"Cannot connect"];
  logs:asc system "ls ",.replay.cfg.logDir,"/*.log 2>/dev/null";
  if[0=count logs; '"No log files"];
  logfile:hsym `$first logs;
  -1 "Replaying: ",1_string logfile;
  bytes:read1 logfile;
  n:count[bytes] div .replay.cfg.msgLen;
  -1 "Messages: ",string n;
  hdr:0x0100000099000000;
  start:.z.p;
  i:0;
  while[i < n;
    msg:-9!hdr,bytes[(.replay.cfg.msgLen*i)+til .replay.cfg.msgLen];
    neg[h] msg;
    i+:1;
  ];
  neg[h][];
  elapsed:(.z.p - start) % 1e9;
  rate:floor n % 0.001 | elapsed;
  -1 "Done: ",string[n]," msgs in ",string[elapsed],"s = ",string[rate]," msg/s";
  hclose h;
  };

-1 "Replay ready - target port ",string .replay.cfg.port;
-1 "Run .replay.run[] to start";
