--!strict

local Types = {}


export type NetworkConfig = {
	-- Rate Limiting
	MaxRateLimit: number,
	MaxRateLimitPerChannel: number,

	-- Payload Limits
	MaxStringLength: number,
	MaxPayloadSize: number,
	MaxSerializationDepth: number,

	-- Batching
	BatchLimit: number,
	MaxQueueSize: number,
	QueueWarningThreshold: number,

	-- Circuit Breaker
	CircuitBreakerThreshold: number,
	CircuitBreakerResetTime: number,

	-- Buffer Pool
	BufferPoolSize: number,
	DefaultBufferSize: number,

	-- Invoke System
	InvokeDefaultTimeout: number,
	MaxPendingInvokesPerPlayer: number,

	-- Misc
	Debug: boolean,
	MaxDeserializationIterations: number,

	-- Internal
	Started: boolean,
}

export type PromiseStatus = "Pending" | "Resolved" | "Rejected" | "Cancelled"

export type Promise<T> = {
	_status: PromiseStatus,
	_value: any,
	_callbacks: {(T) -> ()},
	_errbacks: {(any) -> ()},
	_finallybacks: {() -> ()},

	andThen: (self: Promise<T>, onResolved: ((T) -> any)?, onRejected: ((any) -> any)?) -> Promise<any>,
	catch: (self: Promise<T>, onRejected: (any) -> any) -> Promise<T>,
	finally: (self: Promise<T>, onFinally: () -> ()) -> Promise<T>,
	await: (self: Promise<T>, timeout: number?) -> (boolean, any),
	cancel: (self: Promise<T>) -> (),
	getStatus: (self: Promise<T>) -> PromiseStatus,
}

export type ChannelMetrics = {
	Count: number,
	Errors: number,
}

export type MetricsData = {
	TotalEvents: number,
	TotalErrors: number,
	RateLimitHits: number,
	CircuitBreakerTrips: number,
	EventsPerSecond: number,
	EventsThisSecond: number,
	LastSecondReset: number,
	PackErrors: number,
	UnpackErrors: number,
	ByChannel: {[string]: ChannelMetrics},

	InvokePendingRequests: number,
	InvokeTimeouts: number,
	InvokeErrors: number,
	InvokeSuccesses: number,
	InvokeRejectedDuplicates: number,
}

export type MetricsSnapshot = {
	QueueSize: number,
	EventsPerSecond: number,
	ErrorRate: number,
	BrokenCircuits: number,
	InvokePendingRequests: number,
}

export type FullMetrics = {
	TotalEvents: number,
	EventsPerSecond: number,
	ErrorRate: number,
	RateLimitHits: number,
	CircuitBreakerTrips: number,
	PackErrors: number,
	UnpackErrors: number,
	QueueSize: number,
	ByChannel: {[string]: ChannelMetrics},
	InvokePendingRequests: number,
	InvokeTimeouts: number,
	InvokeErrors: number,
	InvokeSuccesses: number,
	InvokeRejectedDuplicates: number,
}

export type HealthStatus = "HEALTHY" | "DEGRADED" | "CRITICAL"

export type HealthReport = {
	Status: HealthStatus,
	Healthy: boolean,
	Issues: {string},
	Metrics: MetricsSnapshot,
}

export type RateLimitData = {
	Count: number,
	LastReset: number,
}

export type PlayerRateLimits = {
	[string]: RateLimitData 
}

export type CircuitBreaker = {
	Errors: number,
	LastError: number,
	Broken: boolean,
	LastReset: number,
	LastPlayer: Player?,
}

export type ChannelCallback = (Player?, ...any) -> ()

export type Channel = {
	Callback: ChannelCallback,
}

export type MiddlewareFunction = (player: Player?, eventName: string, args: {any}) -> boolean

export type QueuePacket = {
	eventName: string;
	payload: any;
};


export type InvokeHandler = (Player?, ...any) -> ...any

export type InvokeRequest = {
	Resolve: (any) -> (),
	Reject: (any) -> (),
	Timeout: number,
	TimeoutTask: thread?,
	PlayerId: number?,
}

export type SerializerHandler = {
	Id: number,
	Write: (buffer, number, any, WriteFunction) -> number,
	Read: (buffer, number, ReadFunction) -> (any, number),
}

export type WriteFunction = (buffer, number, any) -> number
export type ReadFunction = (buffer, number) -> (any, number)

export type SerializerHandlers = {
	[string | number]: SerializerHandler
}

export type ContractSchema = (args: {any}) -> (boolean, string?)

export type NetworkContract = {
	Rate: number?,
	Schema: ContractSchema?,
}

export type EventLog = {
	Timestamp: number,
	Channel: string,
	Player: string,
	UserId: number,
	Error: string,
	Args: {any},
}

export type LogLevel = "INFO" | "WARN" | "ERR" | "CRIT" | "DEBUG"

export type Logger = {
	info: (tag: string, msg: string) -> (),
	warn: (tag: string, msg: string) -> (),
	error: (tag: string, msg: string) -> (),
	critical: (tag: string, msg: string) -> (),
	debug: (tag: string, msg: string) -> (),
}

export type KoreghNetAPI = {
	Config: NetworkConfig,

	Start: () -> (),
	Stop: () -> (),
	Send: (eventName: string, ...any) -> (),

	RegisterChannel: (eventName: string, callback: ChannelCallback) -> boolean,
	UnregisterChannel: (eventName: string) -> boolean,

	AddMiddleware: (fn: MiddlewareFunction) -> boolean,
	RemoveMiddleware: (fn: MiddlewareFunction) -> boolean,

	Invoke: (eventName: string, timeout: number?, ...any) -> Promise<any>,
	RegisterInvokeHandler: (eventName: string, handler: InvokeHandler) -> boolean,
	UnregisterInvokeHandler: (eventName: string) -> (),

	Pack: (...any) -> any,
	Unpack: (payload: any) -> {any},

	GetHealth: () -> HealthReport,
	GetMetrics: () -> FullMetrics,
	GetChannelMetrics: (eventName: string) -> ChannelMetrics,
	LogEvent: (eventName: string, player: Player?, err: string, args: {any}) -> (),

	_onEvent: (player: Player?, eventName: string, payload: any) -> (),

	Promise: any,
}

export type GuardCheck<T> = (value: any) -> (boolean, T?)

export type GuardBuilder = {
	string: () -> GuardCheck<string>,
	number: () -> GuardCheck<number>,
	boolean: () -> GuardCheck<boolean>,
	table: () -> GuardCheck<{any}>,
	array: (elementCheck: GuardCheck<any>) -> GuardCheck<{any}>,
	optional: (check: GuardCheck<any>) -> GuardCheck<any>,
	union: (...GuardCheck<any>) -> GuardCheck<any>,
	literal: (value: any) -> GuardCheck<any>,
	shape: (schema: {[string]: GuardCheck<any>}) -> GuardCheck<{[string]: any}>,
}

export type Serializable = 
	string | number | boolean | nil | 
buffer | {[any]: Serializable} | 
Vector3 | Vector2 | CFrame | Color3 | 
Instance

export type PackedData = buffer | {any}

export type NetworkBatch = {QueuePacket}

Types.Promise = nil :: Promise<any>?
Types.NetworkConfig = nil :: NetworkConfig?
Types.HealthReport = nil :: HealthReport?
Types.ChannelCallback = nil :: ChannelCallback?
Types.MiddlewareFunction = nil :: MiddlewareFunction?
Types.InvokeHandler = nil :: InvokeHandler?

return Types
