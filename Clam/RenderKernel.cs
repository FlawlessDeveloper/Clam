﻿using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Cloo;
using JetBrains.Annotations;
using OpenTK;

namespace Clam
{
    interface IParameterSet
    {
        void ApplyToKernel(ComputeKernel kernel, ref int startIndex);
        void UnRegister();
    }

    class RenderKernel : IDisposable
    {
        private readonly ComputeContext _context;
        private readonly string[] _sourcecodes;
        private readonly Dictionary<string, string> _defines;
        private ComputeKernel _kernel;
        private long[] _localSize;

        private RenderKernel(ComputeContext context, ComputeKernel kernel, string[] sourcecodes, Dictionary<string, string> defines)
        {
            _context = context;
            _kernel = kernel;
            _sourcecodes = sourcecodes;
            _defines = defines;
        }

        public ComputeContext ComputeContext { get { return _context; } }

        private static ComputeKernel Compile(ComputeContext context, string[] sourcecodes, Dictionary<string, string> defines)
        {
            var program = new ComputeProgram(context, sourcecodes);
            var device = context.Devices.Single();
            try
            {
                foreach (var define in defines.Where(define => define.Key.Any(char.IsWhiteSpace) || define.Value.Any(char.IsWhiteSpace)))
                {
                    ConsoleHelper.Alert("Invalid define \"" + define.Key + "=" + define.Value + "\": define contained whitespace");
                    return null;
                }
                var options = string.Join(" ", defines.Where(kvp => !string.IsNullOrEmpty(kvp.Value)).Select(kvp => "-D " + kvp.Key + "=" + kvp.Value));
                program.Build(new[] { device }, options, null, IntPtr.Zero);
                var str = program.GetBuildLog(device).Trim();
                if (string.IsNullOrEmpty(str) == false)
                    ConsoleHelper.Alert(str);
                return program.CreateKernel("Main");
            }
            catch (InvalidBinaryComputeException)
            {
                ConsoleHelper.Alert(program.GetBuildLog(device));
                return null;
            }
            catch (BuildProgramFailureComputeException)
            {
                ConsoleHelper.Alert(program.GetBuildLog(device));
                return null;
            }
        }

        private static readonly Regex DefineRegex = new Regex(@"^#ifndef +(\w+)\r?$", RegexOptions.Multiline);
        private static readonly Regex DefineDefaultRegex = new Regex(@"^#define +(\w+) +([^\r\n]+)\r?$", RegexOptions.Multiline);
        private static IEnumerable<string> CollectDefines(IEnumerable<string> sourcecodes)
        {
            return sourcecodes.SelectMany(sourcecode => DefineRegex.Matches(sourcecode).Cast<Match>(), (sourcecode, match) => match.Groups[1].Captures[0].Value);
        }

        private static IEnumerable<KeyValuePair<string, string>> CollectDefaultDefines(IEnumerable<string> sourcecodes)
        {
            return sourcecodes.SelectMany(sourcecode => DefineDefaultRegex.Matches(sourcecode).Cast<Match>(),
                (sourcecode, match) => new KeyValuePair<string, string>(match.Groups[1].Captures[0].Value, match.Groups[2].Captures[0].Value));
        }

        [CanBeNull]
        public static RenderKernel Create(ComputeContext context, string[] sourcecodes)
        {
            var defines = CollectDefines(sourcecodes).ToDictionary(define => define, define => "");
            foreach (var defaultDefine in CollectDefaultDefines(sourcecodes).Where(defaultDefine => defines.ContainsKey(defaultDefine.Key)))
                defines[defaultDefine.Key] = defaultDefine.Value;
            var compilation = Compile(context, sourcecodes, defines);
            return compilation == null ? null : new RenderKernel(context, compilation, sourcecodes, defines);
        }

        public IEnumerable<KeyValuePair<string, string>> Options
        {
            get { return _defines; }
        }

        public XElement SerializeOptions()
        {
            return new XElement("RenderKernelOptions", _defines.Select(kvp => (object)new XElement(kvp.Key, kvp.Value)).ToArray());
        }

        public void LoadOptions(XElement element)
        {
            var bad = false;
            foreach (var xElement in element.Elements())
            {
                var key = xElement.Name.LocalName;
                var value = xElement.Value;
                if (_defines.ContainsKey(key))
                {
                    _defines[key] = value;
                }
                else
                {
                    Console.WriteLine("Option {0} was invalid (did you load the wrong XML?)", key);
                    bad = true;
                }
            }
            if (bad)
                Console.ReadKey(true);
        }

        public void SetOption(string key, string value)
        {
            if (_defines.ContainsKey(key) == false)
                throw new Exception("Define " + key + " does not exist, while trying to set it's value in RenderKernel");
            _defines[key] = value;
        }

        public void Recompile()
        {
            var newKernel = Compile(_context, _sourcecodes, _defines);
            Dispose();
            _kernel = newKernel;
        }

        private long[] GlobalLaunchsizeFor(long[] size)
        {
            var retval = new long[size.Length];
            for (var i = 0; i < size.Length; i++)
                retval[i] = (size[i] + _localSize[i] - 1) / _localSize[i] * _localSize[i];
            return retval;
        }

        public void Render(ComputeBuffer<Vector4> buffer, ComputeCommandQueue queue, IParameterSet parameters, Size windowSize)
        {
            Render(buffer, queue, parameters, windowSize, 1, new Size(0, 0));
        }

        public void Render(ComputeBuffer<Vector4> buffer, ComputeCommandQueue queue, IParameterSet parameters, Size windowSize, int partialRender, Size coordinates)
        {
            if (_kernel == null)
                return;
            lock (_kernel)
            {
                _kernel.SetMemoryArgument(0, buffer);
                _kernel.SetValueArgument(1, windowSize.Width);
                _kernel.SetValueArgument(2, windowSize.Height);
                var kernelNumArgs = 3;
                parameters.ApplyToKernel(_kernel, ref kernelNumArgs);

                var size = new long[] { windowSize.Width, windowSize.Height };
                if (_localSize == null)
                {
                    var localSizeSingle = (long)Math.Pow(queue.Device.MaxWorkGroupSize, 1.0 / size.Length);
                    _localSize = new long[size.Length];
                    for (var i = 0; i < size.Length; i++)
                        _localSize[i] = localSizeSingle;
                }
                var offset = new long[size.Length];
                var offsetCoords = new long[] { coordinates.Width, coordinates.Height };

                if (partialRender > 1)
                {
                    for (var i = 0; i < size.Length; i++)
                        size[i] = (size[i] + partialRender - 1) / partialRender;
                    for (var i = 0; i < size.Length; i++)
                        offset[i] = size[i] * offsetCoords[i];
                }

                var globalSize = GlobalLaunchsizeFor(size);
                queue.Execute(_kernel, offset, globalSize, _localSize, null);
            }
        }

        public void Dispose()
        {
            if (_kernel != null)
            {
                lock (_kernel)
                {
                    _kernel.Program.Dispose();
                    _kernel.Dispose();
                    _kernel = null;
                }
            }
        }
    }
}
