defmodule ROS.Service do
  use GenServer
  use Private
  require Logger

  import ROS.Helpers
  alias ROS.Message.ConnectionHeader, as: ConnHead

  @moduledoc """
  Services allow you to handle synchronous requests.

  All requests to services are blocking. Such is the nature of ROS Service
  calls. This allows you to safely adjust values like joint values of a robot
  by preventing more than one access at once.

      iex> import ROS.Node.Spec
      iex> children = [
      ...>   node(:mynode, [
      ...>     service("/add_two_ints", "rospy_tutorials/AddTwoInts", &MyModule.callback_for_service/1)
      ...>   ]
      ...> ]
      iex> Supervisor.start_link(children, strategy: :one_for_one)
  """

  ## Utility functions

  @doc false
  @spec serialize(struct()) :: binary()
  def serialize(%ROS.Service.Error{message: msg}) do
    # give a 0 byte if the service call failed
    <<0>> <> pack_string(msg)
  end

  def serialize(msg) do
    # give a 1 byte if the service call succeeded
    <<1>> <> ROS.Message.serialize(msg)
  end

  @doc false
  @spec deserialize_request(binary(), binary() | module()) :: struct()
  def deserialize_request(data, type) when is_binary(type) do
    # make sure the type parameter is a module
    # e.g. "rospy_tutorials/AddTwoInts" -> RospyTutorials.AddTwoInts
    deserialize_request(data, ROS.Message.module(type))
  end
  def deserialize_request(data, type) do
    # get the Request submodule
    type = Module.concat(type, Request)

    # deserialize it as a regular message
    ROS.Message.deserialize(data, type)
  end

  @doc false
  @spec deserialize_response(binary(), binary() | module()) :: {:ok, struct()} | {:error, String.t()}
  def deserialize_response(data, type) when is_binary(type) do
    deserialize_response(data, ROS.Message.module(type))
  end
  def deserialize_response(data, type) do
    {status_code, rest} = Satchel.unpack_take(data, :uint8)

    case status_code do
      1 ->
        type = Module.concat(type, Response)

        {:ok, ROS.Message.deserialize(rest, type)}

      0 -> {:error, Bite.drop(rest, 4)}
    end
  end

  ## Server API

  @doc false
  def from_node_name(node_name, opts) do
    String.to_atom(Atom.to_string(node_name) <> "_" <> opts[:service])
  end

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    socket = open_socket()
    port = port_of(socket)

    GenServer.cast(self(), {:accept, socket})

    ROS.MasterApi.register_service(opts, port)

    {:ok, %{service: opts, socket: socket, port: port}}
  end

  @impl GenServer
  # `:gen_tcp.accept/1` blocks until something connects to the socket, so this
  # needs to be a cast
  def handle_cast({:accept, socket}, %{service: service} = state) do
    # don't save this in the :socket key of state
    # this allows us to reuse that socket, which is from `:gen_tcp.listen/2`
    {:ok, socket} = :gen_tcp.accept(socket)

    # put the :init key so that we can catch the connection header and treat
    # it differently from general request messages
    {:noreply, Map.put(state, :init, true)}
  end

  @impl GenServer
  # handle the first message through the pipe. this is always the connection
  # header (or the probe message, which is a type of connection header)
  def handle_info({:tcp, socket, packet}, %{init: true, service: service} = state) do
    partial(packet, state, fn full_message ->
      case ConnHead.parse(full_message) do
        %{probe: true} ->
          # rospy doesn't actually listen for the response to the probe
          # connection header, so there's no use in sending it
          :ok

        _conn_head ->
          # if you receive an honest connection header from a service proxy,
          # send back this service's connection header
          send_conn_header(socket, service)
      end

      # we're not in Kansas anymore
      Map.delete(state, :init)
    end)
  end

  # handle the arrival of requests
  def handle_info({:tcp, socket, packet}, %{service: service} = state) do
    # wait for the whole message to arrive
    partial(packet, state, fn full_message ->
      # parse the request
      request = ROS.Service.deserialize_request(full_message, service[:type])

      # try to do the callback
      try do
        service[:callback].(request)
      rescue
        e in ROS.Service.Error ->
          # make sure to log the error
          Logger.error(fn -> "Error in service call!\n#{inspect(e)}" end)

          # return the error struct
          e
        e ->
          # make sure to log the error
          Logger.error(fn -> "Error in service call!\n#{inspect(e)}" end)

          # 
          %ROS.Service.Error{message: to_string(e)}
      end
      |> ROS.Service.serialize()
      |> send_line(socket)

      state
    end)
  end

  # TCP connections are closed when
  #
  # - a python service proxy makes a probe call
  # - a service proxy request is closed
  # - failures of any sort
  #
  # Generally, the service just stays alive and keeps accepting connections.
  # Note that the socket in `state` is different from the one sent in the
  # `info` message. The one in the `info` message has been accepted already.
  # Trying to reaccept it will fail. The socket in `state` is the socket
  # from the call to `:gen_tcp.listen/2` and can be re-accepted to start a
  # new tcp accepting routine.
  def handle_info({:tcp_closed, _socket}, %{socket: socket} = state) do
    GenServer.cast(self, {:accept, socket})

    {:noreply, state}
  end

  private do
    # open a socket
    # port 0 opens on a random open port
    @spec open_socket(non_neg_integer()) :: :gen_tcp.socket()
    defp open_socket(port \\ 0) do
      # - `:binary` the output data
      # - `packet: 0` read packet in chunks of unspecified size
      # - `active: true` makes it so `:gen_tcp.recv` can't be called. all tcp
      # messages come in as `info` messages to the GenServer
      # - `reuseaddr: true` allow re-accepting on the same port
      {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: 0, active: true, reuseaddr: true])

      # reroute all tcp info messages to this GenServer process
      :ok = :gen_tcp.controlling_process(socket, self())

      socket
    end

    # get the port of a socket
    @spec port_of(:gen_tcp.socket()) :: non_neg_integer()
    defp port_of(socket) do
      {:ok, port} = :inet.port(socket)

      port
    end

    # create and send a serialized connection header given a service
    @spec send_conn_header(:gen_tcp.socket(), Keyword.t()) :: :ok | {:error, atom()}
    defp send_conn_header(socket, service) do
      service
      |> ConnHead.from()
      |> ConnHead.serialize()
      |> send_line(socket)
    end

    # send a packet of binary data out of a socket
    @spec send_line(binary(), :gen_tcp.socket()) :: :ok | {:error, atom()}
    defp send_line(data, socket), do: :gen_tcp.send(socket, data)
  end
end