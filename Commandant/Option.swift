//
//  Option.swift
//  Commandant
//
//  Created by Justin Spahr-Summers on 2014-11-21.
//  Copyright (c) 2014 Carthage. All rights reserved.
//

import Foundation
import LlamaKit

/// Represents a record of options for a command, which can be parsed from
/// a list of command-line arguments.
///
/// This is most helpful when used in conjunction with the `Option` type, and
/// `<*>` and `<|` combinators.
///
/// Example:
///
///		struct LogOptions: OptionsType {
///			let verbosity: Int
///			let outputFilename: String
///			let logName: String
///
///			static func create(verbosity: Int)(outputFilename: String)(logName: String) -> LogOptions {
///				return LogOptions(verbosity: verbosity, outputFilename: outputFilename, logName: logName)
///			}
///
///			static func evaluate(m: CommandMode) -> Result<LogOptions> {
///				return create
///					<*> m <| Option(key: "verbose", defaultValue: 0, usage: "the verbosity level with which to read the logs")
///					<*> m <| Option(key: "outputFilename", defaultValue: "", usage: "a file to print output to, instead of stdout")
///					<*> m <| Option(usage: "the log to read")
///			}
///		}
public protocol OptionsType {
	/// Evaluates this set of options in the given mode.
	///
	/// Returns the parsed options, or an `InvalidArgument` error containing
	/// usage information.
	class func evaluate(m: CommandMode) -> Result<Self>
}

/// Describes an option that can be provided on the command line.
public struct Option<T> {
	/// The key that controls this option. For example, a key of `verbose` would
	/// be used for a `--verbose` option.
	///
	/// If this is nil, this option will not have a corresponding flag, and must
	/// be specified as a plain value at the end of the argument list.
	///
	/// This must be non-nil for a boolean option.
	public let key: String?

	/// The default value for this option. This is the value that will be used
	/// if the option is never explicitly specified on the command line.
	///
	/// If this is nil, this option is always required.
	public let defaultValue: T?

	/// A human-readable string describing the purpose of this option. This will
	/// be shown in help messages.
	///
	/// For boolean operations, this should describe the effect of _not_ using
	/// the default value (i.e., what will happen if you disable/enable the flag
	/// differently from the default).
	public let usage: String

	public init(key: String? = nil, defaultValue: T? = nil, usage: String) {
		self.key = key
		self.defaultValue = defaultValue
		self.usage = usage
	}

	/// Constructs an `InvalidArgument` error that describes how the option was
	/// used incorrectly. `value` should be the invalid value given by the user.
	private func invalidUsageError(value: String) -> NSError {
		let description = "Invalid value for '\(self)': \(value)"
		return NSError(domain: CommandantErrorDomain, code: CommandantError.InvalidArgument.rawValue, userInfo: [ NSLocalizedDescriptionKey: description ])
	}
}

extension Option: Printable {
	public var description: String {
		if let key = key {
			return "--\(key)"
		} else {
			return usage
		}
	}
}

/// Represents a value that can be converted from a command-line argument.
public protocol ArgumentType {
	/// A human-readable name for this type.
	class var name: String { get }

	/// Attempts to parse a value from the given command-line argument.
	class func fromString(string: String) -> Self?
}

extension Int: ArgumentType {
	public static let name = "integer"

	public static func fromString(string: String) -> Int? {
		return string.toInt()
	}
}

extension String: ArgumentType {
	public static let name = "string"

	public static func fromString(string: String) -> String? {
		return string
	}
}

// Inspired by the Argo library:
// https://github.com/thoughtbot/Argo
/*
	Copyright (c) 2014 thoughtbot, inc.

	MIT License

	Permission is hereby granted, free of charge, to any person obtaining
	a copy of this software and associated documentation files (the
	"Software"), to deal in the Software without restriction, including
	without limitation the rights to use, copy, modify, merge, publish,
	distribute, sublicense, and/or sell copies of the Software, and to
	permit persons to whom the Software is furnished to do so, subject to
	the following conditions:

	The above copyright notice and this permission notice shall be
	included in all copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
	EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
	MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
	NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
	LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
	OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
	WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
infix operator <*> {
	associativity left
}

infix operator <| {
	associativity left
	precedence 150
}

/// Applies `f` to the value in the given result.
///
/// In the context of command-line option parsing, this is used to chain
/// together the parsing of multiple arguments. See OptionsType for an example.
public func <*><T, U>(f: T -> U, value: Result<T>) -> Result<U> {
	return value.map(f)
}

/// Applies the function in `f` to the value in the given result.
///
/// In the context of command-line option parsing, this is used to chain
/// together the parsing of multiple arguments. See OptionsType for an example.
public func <*><T, U>(f: Result<(T -> U)>, value: Result<T>) -> Result<U> {
	switch (f, value) {
	case let (.Failure(left), .Failure(right)):
		return failure(combineUsageErrors(left, right))

	case let (.Failure(left), .Success):
		return failure(left)

	case let (.Success, .Failure(right)):
		return failure(right)

	case let (.Success(f), .Success(value)):
		let newValue = f.unbox(value.unbox)
		return success(newValue)
	}
}

/// Evaluates the given option in the given mode.
///
/// If parsing command line arguments, and no value was specified on the command
/// line, the option's `defaultValue` is used.
public func <|<T: ArgumentType>(mode: CommandMode, option: Option<T>) -> Result<T> {
	switch mode {
	case let .Arguments(arguments):
		var stringValue: String?
		if let key = option.key {
			switch arguments.consumeValueForKey(key) {
			case let .Success(value):
				stringValue = value.unbox

			case let .Failure(error):
				return failure(error)
			}
		} else {
			stringValue = arguments.consumePositionalArgument()
		}

		if let stringValue = stringValue {
			if let value = T.fromString(stringValue) {
				return success(value)
			}

			return failure(option.invalidUsageError(stringValue))
		} else if let defaultValue = option.defaultValue {
			return success(defaultValue)
		} else {
			return failure(missingArgumentError(option.description))
		}

	case .Usage:
		return failure(informativeUsageError(option))
	}
}

/// Evaluates the given boolean option in the given mode.
///
/// If parsing command line arguments, and no value was specified on the command
/// line, the option's `defaultValue` is used.
public func <|(mode: CommandMode, option: Option<Bool>) -> Result<Bool> {
	precondition(option.key != nil)

	switch mode {
	case let .Arguments(arguments):
		if let value = arguments.consumeBooleanKey(option.key!) {
			return success(value)
		} else if let defaultValue = option.defaultValue {
			return success(defaultValue)
		} else {
			return failure(missingArgumentError(option.description))
		}

	case .Usage:
		return failure(informativeUsageError(option))
	}
}
