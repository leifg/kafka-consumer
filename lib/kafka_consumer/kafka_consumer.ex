defmodule KafkaConsumer do
  use GenServer
  alias KafkaConsumer.Utils

  defmodule Settings do
    defstruct topic: "",
     partition: 0,
     handler: nil,
     handler_pool: nil
  end

  @type settings :: %Settings{topic: String.t,
   partition: number,
   handler: term(),
   handler_pool: atom
 }

  def start_link(settings) do
    GenServer.start_link(__MODULE__, settings, [])
  end

  ### GenServer Callbacks

  def init(%{topic: topic, partition: partition} = settings) do
    consumer_name = [topic, partition] |> Enum.join("$") |> String.to_atom
    worker_name = [topic, partition, "stream"] |> Enum.join("$") |> String.to_atom
    send self(), {:registry, consumer_name}
    send self(), {:consume, Map.put(settings, :worker_name, worker_name)}

    {:ok, %{topic: topic, partition: partition,
     worker_name: worker_name, consumer_name: consumer_name}}
  end

  def handle_info({:registry, consumer_name}, state) do
    :gproc.reg({:n, :l, consumer_name})
    {:noreply, state}
  end

  def handle_info({:consume,
      %{topic: topic, partition: partition, worker_name: worker_name} = _settings}, state) do
  spawn_link(fn -> consume({topic, partition, worker_name}, self()) end)
  {:noreply, state}
  end

  def handle_info(:topic_not_found, state) do
    {:stop, :normal, state}
  end

  def terminate(_reason, %{worker_name: worker_name, consumer_name: consumer_name} = _state) do
    :gproc.unreg({:n, :l, consumer_name})
    Utils.stop_stream(worker_name)
    :ok
  end

  ### Internal Functions

  @doc """
    Consume messages from topic or stop consumer if topic not found
  """
  @spec consume(Map.t, pid) :: atom
  def consume(%{topic: topic, partition: partition, worker_name: worker_name,
      handler: handler, handler_pool: handler_pool}, consumer) do
    if Utils.topic_exists?(topic, partition) do
      Utils.prepare_stream(worker_name, {topic, partition})
      for message <- KafkaEx.stream(topic, partition, worker_name: worker_name) do
        :poolboy.transaction(handler_pool, fn(pid) ->
          handler.handle_event(pid, {topic, partition, message})
        end)
      end
    else
      send consumer, :topic_not_found
    end
    :ok
  end
end
