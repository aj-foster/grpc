defmodule GRPC.Integration.ServiceTest do
  use GRPC.Integration.TestCase, async: true

  defmodule FeatureServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service
    alias GRPC.Server

    def get_feature(point, _stream) do
      simple_feature(point)
    end

    def list_features(rectangle, stream0) do
      Enum.reduce([rectangle.lo, rectangle.hi], stream0, fn point, stream ->
        feature = simple_feature(point)
        Server.stream_send(stream, feature)
      end)
    end

    def record_route(req_enum, _stream) do
      points =
        Enum.reduce(req_enum, [], fn point, acc ->
          [point | acc]
        end)

      fake_num = length(points)

      Routeguide.RouteSummary.new(
        point_count: fake_num,
        feature_count: fake_num,
        distance: fake_num,
        elapsed_time: fake_num
      )
    end

    def route_chat(req_enum, stream0) do
      Enum.reduce(req_enum, stream0, fn note, stream ->
        note = %{note | message: "Reply: #{note.message}"}
        Server.stream_send(stream, note)
      end)
    end

    defp simple_feature(point) do
      Routeguide.Feature.new(location: point, name: "#{point.latitude},#{point.longitude}")
    end
  end

  test "Unary RPC works" do
    run_server(FeatureServer, fn port ->
      {:ok, channel} = GRPC.Stub.connect("localhost:#{port}")
      point = Routeguide.Point.new(latitude: 409_146_138, longitude: -746_188_906)
      {:ok, feature} = channel |> Routeguide.RouteGuide.Stub.get_feature(point)
      assert feature == Routeguide.Feature.new(location: point, name: "409146138,-746188906")
    end)
  end

  test "Server streaming RPC works" do
    run_server(FeatureServer, fn port ->
      {:ok, channel} = GRPC.Stub.connect("localhost:#{port}")
      low = Routeguide.Point.new(latitude: 400_000_000, longitude: -750_000_000)
      high = Routeguide.Point.new(latitude: 420_000_000, longitude: -730_000_000)
      rect = Routeguide.Rectangle.new(lo: low, hi: high)
      {:ok, stream} = channel |> Routeguide.RouteGuide.Stub.list_features(rect)

      assert Enum.to_list(stream) == [
               {:ok, Routeguide.Feature.new(location: low, name: "400000000,-750000000")},
               {:ok, Routeguide.Feature.new(location: high, name: "420000000,-730000000")}
             ]
    end)
  end

  test "Client streaming RPC works" do
    run_server(FeatureServer, fn port ->
      {:ok, channel} = GRPC.Stub.connect("localhost:#{port}")
      point1 = Routeguide.Point.new(latitude: 400_000_000, longitude: -750_000_000)
      point2 = Routeguide.Point.new(latitude: 420_000_000, longitude: -730_000_000)
      stream = channel |> Routeguide.RouteGuide.Stub.record_route()
      GRPC.Stub.stream_send(stream, point1)
      GRPC.Stub.stream_send(stream, point2, end_stream: true)
      {:ok, res} = GRPC.Stub.recv(stream)
      assert %Routeguide.RouteSummary{point_count: 2} = res
    end)
  end

  test "Bidirectional streaming RPC works" do
    run_server(FeatureServer, fn port ->
      {:ok, channel} = GRPC.Stub.connect("localhost:#{port}")
      stream = channel |> Routeguide.RouteGuide.Stub.route_chat()

      task =
        Task.async(fn ->
          Enum.each(1..6, fn i ->
            point = Routeguide.Point.new(latitude: 0, longitude: rem(i, 3) + 1)
            note = Routeguide.RouteNote.new(location: point, message: "Message #{i}")
            opts = if i == 6, do: [end_stream: true], else: []
            GRPC.Stub.stream_send(stream, note, opts)
          end)
        end)

      {:ok, result_enum} = GRPC.Stub.recv(stream)
      Task.await(task)

      notes =
        Enum.map(result_enum, fn {:ok, note} ->
          assert "Reply: " <> _msg = note.message
          note
        end)

      assert length(notes) == 6
    end)
  end
end
