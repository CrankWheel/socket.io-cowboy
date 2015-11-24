-module(engineio_data_protocol).
-compile([{no_auto_import, [error/2]}]).
-include("engineio_internal.hrl").
-include_lib("eunit/include/eunit.hrl").

%% The source code was taken and modified from https://github.com/yrashk/socket.io-erlang/blob/master/src/socketio_data_v1.erl

-export([encode_polling_json_packets_v1/2, encode_polling_xhr_packets_v1/2, encode_v1/1,decode_v1/1, decode_v1_for_websocket/1]).

encode_v1(Messages) when is_list(Messages) ->
    lists:map(fun(Message) ->
        encode_v1(Message)
    end, Messages);
encode_v1(disconnect) ->
    <<"41">>;
encode_v1({pong, Data}) ->
    <<"3", Data/binary>>;
encode_v1({message, Message}) ->
    <<"4", Message/binary>>;
encode_v1(nop) ->
    <<"6">>.

encode_polling_xhr_packets_v1(PacketList, Base64) ->
    case Base64 of
        false ->
            lists:foldl(fun(Packet, AccIn) ->
                PacketLen = [list_to_integer([D]) || D <- integer_to_list(byte_size(Packet))],
                PacketLenBin = list_to_binary(PacketLen),
                <<AccIn/binary, 0, PacketLenBin/binary, 255, Packet/binary>>
            end, <<>>, PacketList);
        true ->
            lists:foldl(fun(Packet, AccIn) ->
                PakcetLenBin = binary:list_to_bin(integer_to_list(binary_utf8_len(Packet))),
                <<AccIn/binary, PacketLenBin/binary, $:, Packet/binary>>
            end, <<>>, PacketList)
    end.

encode_polling_json_packets_v1(PacketList, JsonP) ->
    % TODO(joi): I'm pretty sure we could optimize by using an iolist rather
    % than building an increasingly-larger binary...
    Payload = lists:foldl(fun(Packet, AccIn) ->
        ResultLenBin = integer_to_binary(byte_size(Packet)),
        Packet2 = escape_character(Packet, <<"\\">>),
        Packet3 = escape_character(Packet2, <<"\"">>),
        Packet4 = escape_character(Packet3, <<"\\n">>),
        <<AccIn/binary, ResultLenBin/binary, ":", Packet4/binary>>
    end, <<>>, PacketList),
    <<"___eio[", JsonP/binary, "](\"", Payload/binary, "\");">>.

escape_character(Data, CharBin) ->
    binary:replace(Data, CharBin, <<"\\", CharBin/binary>>, [global]).

binary_utf8_len(Binary) ->
    binary_utf8_len(Binary, 0).
binary_utf8_len(<<>>, Len) ->
    Len;
binary_utf8_len(<<_X/utf8, Binary/binary>>, Len) ->
    binary_utf8_len(Binary, Len+1).

%%% PARSING
decode_v1_for_websocket(Packet) when is_binary(Packet) ->
    [decode_packet_v1(Packet)].
decode_v1(BodyBin) when is_binary(BodyBin) ->
    decode_v1(parse_polling_body_for_v1(BodyBin));
decode_v1(Packets) when is_list(Packets) ->
    lists:map(fun(Packet) ->
        decode_packet_v1(Packet)
    end, Packets).

decode_packet_v1(<<"1">>) -> disconnect;
decode_packet_v1(<<"2", Rest/binary>>) ->
    {ping, Rest};
decode_packet_v1(<<"4", Rest/binary>>) ->
    {message, Rest};
decode_packet_v1(<<"5">>) -> upgrade.

parse_polling_body_for_v1(Body) ->
    parse_polling_body_for_v1(Body, []).

parse_polling_body_for_v1(<<>>, Packets) ->
    Packets;
parse_polling_body_for_v1(Rest, Packets) ->
    [LengthBin, RestBin] = binary:split(Rest, <<":">>),
    Length = binary_to_integer(LengthBin),
    <<Packet:Length/binary, Rest2/binary>> = RestBin,
    parse_polling_body_for_v1(Rest2, [Packet | Packets]).

%%% Tests based off the examples on the page
%%% ENCODING
disconnect_test_() ->
    [?_assertEqual(<<"41">>, encode_v1(disconnect))].

connect_test_() -> []. % Only need to read, never to encode

%% No format specified in the spec.
heartbeat_test() ->
    [?_assertEqual(<<"3test">>, encode_v1({pong, <<"test">>}))].

message_test_() ->
    [?_assertEqual(<<"4test">>, encode_v1({message, <<"test">>}))].

%% DECODING TESTS
d_disconnect_test_() ->
    [?_assertEqual(disconnect, decode_packet_v1(<<"1">>))].

d_connect_test_() ->
    [].

%%% No format specified in the spec.
d_heartbeat_test() ->
    [?_assertEqual(heartbeat, decode_packet(heartbeat())),
        ?_assertEqual({ping, <<"test">>}, decode_packet_v1(<<"2test">>))].

decode_v1_regression_test_() ->
    [
        ?_assertEqual([{message, <<"{\"userName\":\"user485\",\"message\":\"styx\"}">>}],
                      decode_v1(<<"40:4{\"userName\":\"user485\",\"message\":\"styx\"}">>))
    ].

encode_v1_regression_test_() ->
    [
        ?_assertEqual([<<"4{\"userName\":\"user847\",\"message\":\"hello\"}">>],
                      encode_v1([{message,<<"{\"userName\":\"user847\",\"message\":\"hello\"}">>}]))
    ].
