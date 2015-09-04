var app = require('express')();
var http = require('http').Server(app);
var io = require('socket.io')(http);

app.get('/', function(req, res){
  res.sendFile(__dirname + '/index.html');
});

app.get('/stress.html', function(req, res){
  res.sendFile(__dirname + '/stress.html');
});

io.on('connection', function(socket){
  socket.on('m', function(msg){
      io.emit('m', msg);
  });
});

http.listen(8080, function(){
  console.log('listening on *:8080');
});
