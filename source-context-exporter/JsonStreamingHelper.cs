
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace SourceContext
{
    public sealed class JsonNodeInfo
    {
        public string Name { get; set; }
        public string KeyName { get; set; }
        public string ExactPointer { get; set; }
        public string StructuralPointer { get; set; }
        public long StartOffset { get; set; }
        public long EndOffset { get; set; }
        public string NodeType { get; set; }
        public bool HasChildren { get; set; }
        public string Preview { get; set; }

        public long ParentStartOffset { get; set; }
        public string ParentNodeType { get; set; }
        public string ParentExactPointer { get; set; }
        public string ParentStructuralPointer { get; set; }
        public string ParentKeyName { get; set; }
    }

    public sealed class JsonChildPage
    {
        public JsonChildPage()
        {
            Children = new List<JsonNodeInfo>();
            NextOffset = -1;
        }

        public List<JsonNodeInfo> Children { get; set; }
        public bool HasMore { get; set; }
        public long NextOffset { get; set; }
        public int NextIndex { get; set; }
    }

    public sealed class JsonFieldInfo
    {
        public string Key { get; set; }
        public string NodeType { get; set; }
        public string Preview { get; set; }
        public bool CanMatchValue { get; set; }
        public string ValueType { get; set; }
        public string ValueText { get; set; }
        public string ValueHash { get; set; }
    }

    public sealed class JsonFieldList
    {
        public JsonFieldList()
        {
            Fields = new List<JsonFieldInfo>();
        }

        public List<JsonFieldInfo> Fields { get; set; }
        public bool Truncated { get; set; }
    }

    public sealed class JsonFieldCondition
    {
        public string Key { get; set; }
        public bool MatchValue { get; set; }
        public string ValueType { get; set; }
        public string ValueText { get; set; }
        public string ValueHash { get; set; }
    }

    public sealed class JsonFilterRule
    {
        public string Id { get; set; }
        public string Scope { get; set; }
        public string Action { get; set; }
        public string PathMode { get; set; }
        public string Selector { get; set; }
        public string NodeName { get; set; }
        public JsonFieldCondition[] Conditions { get; set; }
        public bool Enabled { get; set; }
    }

    public sealed class JsonPreviewResult
    {
        public bool Kept { get; set; }
        public bool Truncated { get; set; }
    }

    public static class JsonStreamingHelper
    {
        private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);
        private static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);

        private sealed class ByteScanner : IDisposable
        {
            private readonly FileStream _stream;

            public ByteScanner(string path)
            {
                _stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 65536, FileOptions.SequentialScan);
            }

            public long Position
            {
                get { return _stream.Position; }
            }

            public long Length
            {
                get { return _stream.Length; }
            }

            public int Read()
            {
                return _stream.ReadByte();
            }

            public int Peek()
            {
                int value = _stream.ReadByte();
                if (value >= 0)
                {
                    _stream.Position--;
                }
                return value;
            }

            public void Seek(long position)
            {
                _stream.Seek(position, SeekOrigin.Begin);
            }

            public void SkipWhitespace()
            {
                while (true)
                {
                    int value = Peek();
                    if (IsWhitespace(value))
                    {
                        Read();
                        continue;
                    }
                    return;
                }
            }

            public void SkipBomIfPresent()
            {
                if (Position != 0 || Length == 0)
                {
                    return;
                }

                int first = Read();
                if (first < 0)
                {
                    return;
                }

                if (first == 0xEF)
                {
                    int second = Read();
                    int third = Read();
                    if (second == 0xBB && third == 0xBF)
                    {
                        return;
                    }
                }
                else if (first == 0xFF || first == 0xFE)
                {
                    throw new InvalidDataException("Only UTF-8 JSON files are supported by the JSON structure filter.");
                }

                Seek(0);
            }

            public void Dispose()
            {
                _stream.Dispose();
            }
        }

        private sealed class JsonOutputMark
        {
            public long Position;
            public long LogicalBytes;
        }

        private sealed class PreviewLimitException : Exception
        {
        }

        private sealed class JsonOutputWriter : IDisposable
        {
            private readonly FileStream _stream;
            private readonly StreamWriter _writer;
            private readonly long _maxBytes;
            private long _logicalBytes;

            public JsonOutputWriter(string path, long maxBytes)
            {
                _stream = new FileStream(path, FileMode.Create, FileAccess.ReadWrite, FileShare.Read, 65536, FileOptions.SequentialScan);
                _writer = new StreamWriter(_stream, Utf8NoBom, 65536);
                _maxBytes = maxBytes;
                _logicalBytes = 0;
            }

            public void Write(string value)
            {
                if (value == null)
                {
                    return;
                }

                long bytes = Utf8NoBom.GetByteCount(value);
                if (_maxBytes >= 0 && _logicalBytes + bytes > _maxBytes)
                {
                    throw new PreviewLimitException();
                }

                _writer.Write(value);
                _logicalBytes += bytes;
            }

            public void Write(char value)
            {
                Write(value.ToString());
            }

            public void WriteLine()
            {
                Write(Environment.NewLine);
            }

            public JsonOutputMark Mark()
            {
                _writer.Flush();
                return new JsonOutputMark
                {
                    Position = _stream.Position,
                    LogicalBytes = _logicalBytes
                };
            }

            public void Rollback(JsonOutputMark mark)
            {
                _writer.Flush();
                _stream.SetLength(mark.Position);
                _stream.Seek(mark.Position, SeekOrigin.Begin);
                _logicalBytes = mark.LogicalBytes;
            }

            public void Flush()
            {
                _writer.Flush();
            }

            public void Dispose()
            {
                _writer.Dispose();
                _stream.Dispose();
            }
        }

        private sealed class NodeContext
        {
            public string ExactPointer;
            public string StructuralPointer;
            public string KeyName;
            public string NodeType;
            public long StartOffset;
        }

        private sealed class RuleChoice
        {
            public JsonFilterRule Rule;
            public int ScopeRank;
            public int PathRank;
            public int ValueConditionCount;
            public int ConditionCount;
            public int NodeNameRank;
            public int ActionRank;
        }

        private sealed class NodeWriteResult
        {
            public bool Kept;
            public bool IsArray;
            public bool IsEmptyArray;
        }

        public static JsonNodeInfo GetRootInfo(string filePath)
        {
            using (ByteScanner scanner = new ByteScanner(filePath))
            {
                scanner.SkipBomIfPresent();
                scanner.SkipWhitespace();
                long start = scanner.Position;
                int first = scanner.Peek();
                if (first < 0)
                {
                    throw new InvalidDataException("The JSON file is empty.");
                }

                string type = GetNodeType(first);
                return new JsonNodeInfo
                {
                    Name = "$",
                    KeyName = null,
                    ExactPointer = String.Empty,
                    StructuralPointer = String.Empty,
                    StartOffset = start,
                    EndOffset = -1,
                    NodeType = type,
                    HasChildren = type == "object" || type == "array",
                    Preview = type == "object" ? "{...}" : (type == "array" ? "[...]" : type),
                    ParentStartOffset = -1,
                    ParentNodeType = null,
                    ParentExactPointer = null,
                    ParentStructuralPointer = null,
                    ParentKeyName = null
                };
            }
        }

        public static JsonChildPage GetChildrenPage(
            string filePath,
            long parentStartOffset,
            string parentNodeType,
            string parentExactPointer,
            string parentStructuralPointer,
            string parentKeyName,
            long resumeOffset,
            int nextIndex,
            int pageSize)
        {
            if (pageSize <= 0)
            {
                pageSize = 200;
            }

            if (parentNodeType != "object" && parentNodeType != "array")
            {
                return new JsonChildPage();
            }

            using (ByteScanner scanner = new ByteScanner(filePath))
            {
                JsonChildPage page = new JsonChildPage();
                bool isObject = parentNodeType == "object";
                int currentIndex = nextIndex;

                if (resumeOffset >= 0)
                {
                    scanner.Seek(resumeOffset);
                }
                else
                {
                    scanner.Seek(parentStartOffset);
                    int opener = scanner.Read();
                    if ((isObject && opener != '{') || (!isObject && opener != '['))
                    {
                        throw new InvalidDataException("The cached JSON node offset no longer points to the expected container. The file may have changed.");
                    }
                    scanner.SkipWhitespace();
                }

                int expectedClose = isObject ? '}' : ']';
                if (scanner.Peek() == expectedClose)
                {
                    scanner.Read();
                    return page;
                }

                while (page.Children.Count < pageSize)
                {
                    scanner.SkipWhitespace();
                    if (scanner.Peek() == expectedClose)
                    {
                        scanner.Read();
                        return page;
                    }

                    string displayName;
                    string keyName;
                    string exactSegment;
                    string structuralSegment;

                    if (isObject)
                    {
                        bool ignoredTruncation;
                        string propertyName = ReadString(scanner, -1, out ignoredTruncation);
                        scanner.SkipWhitespace();
                        Expect(scanner, ':');
                        scanner.SkipWhitespace();

                        displayName = propertyName;
                        keyName = propertyName;
                        exactSegment = EncodePointerSegment(propertyName);
                        structuralSegment = exactSegment;
                    }
                    else
                    {
                        displayName = "[" + currentIndex.ToString(CultureInfo.InvariantCulture) + "]";
                        keyName = null;
                        exactSegment = currentIndex.ToString(CultureInfo.InvariantCulture);
                        structuralSegment = "*";
                    }

                    long valueStart = scanner.Position;
                    int first = scanner.Peek();
                    if (first < 0)
                    {
                        throw new InvalidDataException("Unexpected end of JSON while reading a child value.");
                    }

                    string nodeType = GetNodeType(first);
                    string preview;
                    long valueEnd;

                    if (nodeType == "object" || nodeType == "array")
                    {
                        SkipValue(scanner);
                        valueEnd = scanner.Position;
                        preview = nodeType == "object" ? "{...}" : "[...]";
                    }
                    else if (nodeType == "string")
                    {
                        bool truncated;
                        string value = ReadString(scanner, 120, out truncated);
                        valueEnd = scanner.Position;
                        preview = truncated ? value + "..." : value;
                    }
                    else
                    {
                        string token = ReadPrimitiveToken(scanner, 120, out valueEnd);
                        preview = token;
                    }

                    page.Children.Add(new JsonNodeInfo
                    {
                        Name = displayName,
                        KeyName = keyName,
                        ExactPointer = AppendPointer(parentExactPointer, exactSegment),
                        StructuralPointer = AppendPointer(parentStructuralPointer, structuralSegment),
                        StartOffset = valueStart,
                        EndOffset = valueEnd,
                        NodeType = nodeType,
                        HasChildren = nodeType == "object" || nodeType == "array",
                        Preview = preview,
                        ParentStartOffset = parentStartOffset,
                        ParentNodeType = parentNodeType,
                        ParentExactPointer = parentExactPointer,
                        ParentStructuralPointer = parentStructuralPointer,
                        ParentKeyName = parentKeyName
                    });

                    if (!isObject)
                    {
                        currentIndex++;
                    }

                    scanner.SkipWhitespace();
                    int separator = scanner.Peek();
                    if (separator == ',')
                    {
                        scanner.Read();
                        scanner.SkipWhitespace();

                        if (page.Children.Count >= pageSize)
                        {
                            page.HasMore = true;
                            page.NextOffset = scanner.Position;
                            page.NextIndex = currentIndex;
                            return page;
                        }
                        continue;
                    }

                    if (separator == expectedClose)
                    {
                        scanner.Read();
                        page.NextIndex = currentIndex;
                        return page;
                    }

                    throw new InvalidDataException("Expected ',' or closing bracket while reading JSON children.");
                }

                page.NextIndex = currentIndex;
                return page;
            }
        }

        public static JsonFieldList GetObjectFields(string filePath, long objectStartOffset, int maxFields)
        {
            if (maxFields <= 0)
            {
                maxFields = 200;
            }

            JsonFieldList result = new JsonFieldList();

            using (ByteScanner scanner = new ByteScanner(filePath))
            {
                scanner.Seek(objectStartOffset);
                scanner.SkipWhitespace();
                Expect(scanner, '{');
                scanner.SkipWhitespace();

                if (scanner.Peek() == '}')
                {
                    scanner.Read();
                    return result;
                }

                while (true)
                {
                    if (result.Fields.Count >= maxFields)
                    {
                        result.Truncated = true;
                        return result;
                    }

                    bool ignoredTruncation;
                    string key = ReadString(scanner, -1, out ignoredTruncation);
                    scanner.SkipWhitespace();
                    Expect(scanner, ':');
                    scanner.SkipWhitespace();

                    int first = scanner.Peek();
                    if (first < 0)
                    {
                        throw new InvalidDataException("Unexpected end of JSON while reading object fields.");
                    }

                    string nodeType = GetNodeType(first);
                    JsonFieldInfo field = new JsonFieldInfo();
                    field.Key = key;
                    field.NodeType = nodeType;

                    if (nodeType == "string")
                    {
                        bool truncated;
                        string valueHash;
                        string value = ReadStringWithHash(scanner, 4096, out truncated, out valueHash);
                        field.CanMatchValue = true;
                        field.ValueType = "string";
                        field.ValueText = value;
                        field.ValueHash = valueHash;

                        string previewValue = value;
                        if (previewValue.Length > 160)
                        {
                            previewValue = previewValue.Substring(0, 160);
                        }
                        field.Preview = "\"" + EscapePreview(previewValue) + (truncated || value.Length > 160 ? "..." : String.Empty) + "\"";
                    }
                    else if (nodeType == "number" || nodeType == "boolean" || nodeType == "null")
                    {
                        long ignoredEnd;
                        string token = ReadPrimitiveToken(scanner, -1, out ignoredEnd);
                        ValidatePrimitiveToken(token);
                        field.CanMatchValue = true;
                        field.ValueType = nodeType;
                        field.ValueText = token;
                        field.ValueHash = ComputeScalarHash(nodeType, token);
                        field.Preview = token;
                    }
                    else
                    {
                        SkipValue(scanner);
                        field.CanMatchValue = false;
                        field.ValueType = null;
                        field.ValueText = null;
                        field.Preview = nodeType == "object" ? "{...}" : "[...]";
                    }

                    result.Fields.Add(field);

                    scanner.SkipWhitespace();
                    int separator = scanner.Peek();
                    if (separator == ',')
                    {
                        scanner.Read();
                        scanner.SkipWhitespace();
                        continue;
                    }

                    if (separator == '}')
                    {
                        scanner.Read();
                        return result;
                    }

                    throw new InvalidDataException("Expected ',' or '}' while reading object fields.");
                }
            }
        }

        public static bool EvaluateNodeIncluded(
            string filePath,
            JsonNodeInfo node,
            JsonFilterRule[] rules,
            bool inheritedIncluded)
        {
            if (node == null)
            {
                throw new ArgumentNullException("node");
            }

            using (ByteScanner scanner = new ByteScanner(filePath))
            {
                NodeContext context = new NodeContext();
                context.ExactPointer = node.ExactPointer == null ? String.Empty : node.ExactPointer;
                context.StructuralPointer = node.StructuralPointer == null ? String.Empty : node.StructuralPointer;
                context.KeyName = node.KeyName;
                context.NodeType = node.NodeType;
                context.StartOffset = node.StartOffset;

                JsonFilterRule direct = FindBestDirectRule(scanner, context, rules);
                if (direct == null)
                {
                    return inheritedIncluded;
                }

                return IsIncludeAction(direct.Action);
            }
        }

        public static void WriteFilteredFile(
            string inputPath,
            string outputPath,
            JsonFilterRule[] rules,
            bool removeEmptyArrays)
        {
            using (ByteScanner scanner = new ByteScanner(inputPath))
            using (JsonOutputWriter writer = new JsonOutputWriter(outputPath, -1))
            {
                scanner.SkipBomIfPresent();
                scanner.SkipWhitespace();

                NodeContext root = new NodeContext();
                root.ExactPointer = String.Empty;
                root.StructuralPointer = String.Empty;
                root.KeyName = null;
                root.StartOffset = scanner.Position;
                root.NodeType = GetNodeType(scanner.Peek());

                NodeWriteResult result = WriteValue(scanner, writer, rules, root, true, 0, removeEmptyArrays);
                if (!result.Kept)
                {
                    writer.Write("null");
                }

                scanner.SkipWhitespace();
                if (scanner.Peek() >= 0)
                {
                    throw new InvalidDataException("Unexpected content after the root JSON value.");
                }

                writer.WriteLine();
                writer.Flush();
            }
        }

        public static JsonPreviewResult WriteFilteredSubtreePreview(
            string inputPath,
            string outputPath,
            JsonNodeInfo node,
            JsonFilterRule[] rules,
            bool removeEmptyArrays,
            bool parentIncluded,
            long maxBytes)
        {
            if (node == null)
            {
                throw new ArgumentNullException("node");
            }

            JsonPreviewResult preview = new JsonPreviewResult();

            using (ByteScanner scanner = new ByteScanner(inputPath))
            {
                scanner.Seek(node.StartOffset);

                try
                {
                    using (JsonOutputWriter writer = new JsonOutputWriter(outputPath, maxBytes))
                    {
                        NodeContext context = new NodeContext();
                        context.ExactPointer = node.ExactPointer == null ? String.Empty : node.ExactPointer;
                        context.StructuralPointer = node.StructuralPointer == null ? String.Empty : node.StructuralPointer;
                        context.KeyName = node.KeyName;
                        context.StartOffset = node.StartOffset;
                        context.NodeType = node.NodeType;

                        NodeWriteResult result = WriteValue(scanner, writer, rules, context, parentIncluded, 0, removeEmptyArrays);
                        preview.Kept =
                            result.Kept &&
                            !(removeEmptyArrays && result.IsArray && result.IsEmptyArray && !String.IsNullOrEmpty(node.KeyName));
                        writer.Flush();
                    }
                }
                catch (PreviewLimitException)
                {
                    preview.Kept = true;
                    preview.Truncated = true;
                }
            }

            return preview;
        }

        private static NodeWriteResult WriteValue(
            ByteScanner scanner,
            JsonOutputWriter writer,
            JsonFilterRule[] rules,
            NodeContext context,
            bool inheritedIncluded,
            int indent,
            bool removeEmptyArrays)
        {
            scanner.SkipWhitespace();
            context.StartOffset = scanner.Position;
            int first = scanner.Peek();
            if (first < 0)
            {
                throw new InvalidDataException("Unexpected end of JSON while writing a value.");
            }

            context.NodeType = GetNodeType(first);

            JsonFilterRule direct = FindBestDirectRule(scanner, context, rules);
            bool effectiveIncluded = direct == null ? inheritedIncluded : IsIncludeAction(direct.Action);

            scanner.Seek(context.StartOffset);

            if (context.NodeType == "object")
            {
                return WriteObject(scanner, writer, rules, context, effectiveIncluded, indent, removeEmptyArrays);
            }

            if (context.NodeType == "array")
            {
                return WriteArray(scanner, writer, rules, context, effectiveIncluded, indent, removeEmptyArrays);
            }

            if (!effectiveIncluded)
            {
                SkipValue(scanner);
                return new NodeWriteResult { Kept = false, IsArray = false, IsEmptyArray = false };
            }

            if (first == '"')
            {
                bool ignoredTruncation;
                string value = ReadString(scanner, -1, out ignoredTruncation);
                WriteJsonString(writer, value);
            }
            else
            {
                long ignoredEnd;
                string token = ReadPrimitiveToken(scanner, -1, out ignoredEnd);
                ValidatePrimitiveToken(token);
                writer.Write(token);
            }

            return new NodeWriteResult { Kept = true, IsArray = false, IsEmptyArray = false };
        }

        private static NodeWriteResult WriteObject(
            ByteScanner scanner,
            JsonOutputWriter writer,
            JsonFilterRule[] rules,
            NodeContext context,
            bool effectiveIncluded,
            int indent,
            bool removeEmptyArrays)
        {
            JsonOutputMark objectMark = writer.Mark();
            Expect(scanner, '{');
            scanner.SkipWhitespace();

            writer.Write('{');

            if (scanner.Peek() == '}')
            {
                scanner.Read();

                if (!effectiveIncluded)
                {
                    writer.Rollback(objectMark);
                    return new NodeWriteResult { Kept = false, IsArray = false, IsEmptyArray = false };
                }

                writer.Write('}');
                return new NodeWriteResult { Kept = true, IsArray = false, IsEmptyArray = false };
            }

            bool wroteAny = false;

            while (true)
            {
                bool ignoredTruncation;
                string propertyName = ReadString(scanner, -1, out ignoredTruncation);
                scanner.SkipWhitespace();
                Expect(scanner, ':');
                scanner.SkipWhitespace();

                long childStart = scanner.Position;
                int childFirst = scanner.Peek();
                if (childFirst < 0)
                {
                    throw new InvalidDataException("Unexpected end of JSON while filtering an object.");
                }

                string encoded = EncodePointerSegment(propertyName);

                NodeContext childContext = new NodeContext();
                childContext.ExactPointer = AppendPointer(context.ExactPointer, encoded);
                childContext.StructuralPointer = AppendPointer(context.StructuralPointer, encoded);
                childContext.KeyName = propertyName;
                childContext.StartOffset = childStart;
                childContext.NodeType = GetNodeType(childFirst);

                JsonOutputMark propertyMark = writer.Mark();

                if (wroteAny)
                {
                    writer.Write(',');
                }
                writer.WriteLine();
                WriteIndent(writer, indent + 1);
                WriteJsonString(writer, propertyName);
                writer.Write(": ");

                NodeWriteResult childResult = WriteValue(
                    scanner,
                    writer,
                    rules,
                    childContext,
                    effectiveIncluded,
                    indent + 1,
                    removeEmptyArrays);

                bool pruneEmptyArrayProperty =
                    removeEmptyArrays &&
                    childResult.Kept &&
                    childResult.IsArray &&
                    childResult.IsEmptyArray;

                if (!childResult.Kept || pruneEmptyArrayProperty)
                {
                    writer.Rollback(propertyMark);
                }
                else
                {
                    wroteAny = true;
                }

                scanner.SkipWhitespace();
                int separator = scanner.Peek();
                if (separator == ',')
                {
                    scanner.Read();
                    scanner.SkipWhitespace();
                    continue;
                }

                if (separator == '}')
                {
                    scanner.Read();
                    break;
                }

                throw new InvalidDataException("Expected ',' or '}' while filtering a JSON object.");
            }

            if (!effectiveIncluded && !wroteAny)
            {
                writer.Rollback(objectMark);
                return new NodeWriteResult { Kept = false, IsArray = false, IsEmptyArray = false };
            }

            if (wroteAny)
            {
                writer.WriteLine();
                WriteIndent(writer, indent);
            }

            writer.Write('}');

            return new NodeWriteResult
            {
                Kept = true,
                IsArray = false,
                IsEmptyArray = false
            };
        }

        private static NodeWriteResult WriteArray(
            ByteScanner scanner,
            JsonOutputWriter writer,
            JsonFilterRule[] rules,
            NodeContext context,
            bool effectiveIncluded,
            int indent,
            bool removeEmptyArrays)
        {
            JsonOutputMark arrayMark = writer.Mark();
            Expect(scanner, '[');
            scanner.SkipWhitespace();

            writer.Write('[');

            if (scanner.Peek() == ']')
            {
                scanner.Read();

                if (!effectiveIncluded)
                {
                    writer.Rollback(arrayMark);
                    return new NodeWriteResult { Kept = false, IsArray = true, IsEmptyArray = true };
                }

                writer.Write(']');
                return new NodeWriteResult { Kept = true, IsArray = true, IsEmptyArray = true };
            }

            bool wroteAny = false;
            int sourceIndex = 0;

            while (true)
            {
                long childStart = scanner.Position;
                int childFirst = scanner.Peek();
                if (childFirst < 0)
                {
                    throw new InvalidDataException("Unexpected end of JSON while filtering an array.");
                }

                string exactSegment = sourceIndex.ToString(CultureInfo.InvariantCulture);

                NodeContext childContext = new NodeContext();
                childContext.ExactPointer = AppendPointer(context.ExactPointer, exactSegment);
                childContext.StructuralPointer = AppendPointer(context.StructuralPointer, "*");
                childContext.KeyName = null;
                childContext.StartOffset = childStart;
                childContext.NodeType = GetNodeType(childFirst);

                JsonOutputMark elementMark = writer.Mark();

                if (wroteAny)
                {
                    writer.Write(',');
                }
                writer.WriteLine();
                WriteIndent(writer, indent + 1);

                NodeWriteResult childResult = WriteValue(
                    scanner,
                    writer,
                    rules,
                    childContext,
                    effectiveIncluded,
                    indent + 1,
                    removeEmptyArrays);

                if (!childResult.Kept)
                {
                    writer.Rollback(elementMark);
                }
                else
                {
                    wroteAny = true;
                }

                sourceIndex++;
                scanner.SkipWhitespace();
                int separator = scanner.Peek();
                if (separator == ',')
                {
                    scanner.Read();
                    scanner.SkipWhitespace();
                    continue;
                }

                if (separator == ']')
                {
                    scanner.Read();
                    break;
                }

                throw new InvalidDataException("Expected ',' or ']' while filtering a JSON array.");
            }

            if (!effectiveIncluded && !wroteAny)
            {
                writer.Rollback(arrayMark);
                return new NodeWriteResult { Kept = false, IsArray = true, IsEmptyArray = true };
            }

            if (wroteAny)
            {
                writer.WriteLine();
                WriteIndent(writer, indent);
            }

            writer.Write(']');

            return new NodeWriteResult
            {
                Kept = true,
                IsArray = true,
                IsEmptyArray = !wroteAny
            };
        }

        private sealed class ObjectFieldSnapshot
        {
            public bool Exists;
            public HashSet<string> ScalarValues;

            public ObjectFieldSnapshot()
            {
                ScalarValues = new HashSet<string>(StringComparer.Ordinal);
            }
        }

        private static JsonFilterRule FindBestDirectRule(
            ByteScanner scanner,
            NodeContext context,
            JsonFilterRule[] rules)
        {
            if (rules == null || rules.Length == 0)
            {
                return null;
            }

            List<JsonFilterRule> candidates = new List<JsonFilterRule>();
            HashSet<string> requiredKeys = new HashSet<string>(StringComparer.Ordinal);

            for (int i = 0; i < rules.Length; i++)
            {
                JsonFilterRule rule = rules[i];
                if (rule == null || !rule.Enabled)
                {
                    continue;
                }

                if (!RulePathMatches(rule, context))
                {
                    continue;
                }

                if (!String.IsNullOrEmpty(rule.NodeName) &&
                    !String.Equals(rule.NodeName, context.KeyName, StringComparison.Ordinal))
                {
                    continue;
                }

                JsonFieldCondition[] conditions = rule.Conditions;
                if (conditions != null && conditions.Length > 0)
                {
                    if (context.NodeType != "object")
                    {
                        continue;
                    }

                    for (int conditionIndex = 0; conditionIndex < conditions.Length; conditionIndex++)
                    {
                        JsonFieldCondition condition = conditions[conditionIndex];
                        if (condition != null && !String.IsNullOrEmpty(condition.Key))
                        {
                            requiredKeys.Add(condition.Key);
                        }
                    }
                }

                candidates.Add(rule);
            }

            if (candidates.Count == 0)
            {
                return null;
            }

            Dictionary<string, ObjectFieldSnapshot> fieldSnapshot = null;
            if (requiredKeys.Count > 0)
            {
                long restore = scanner.Position;
                try
                {
                    fieldSnapshot = ReadRelevantObjectFields(scanner, context.StartOffset, requiredKeys);
                }
                finally
                {
                    scanner.Seek(restore);
                }
            }

            RuleChoice best = null;
            for (int i = 0; i < candidates.Count; i++)
            {
                JsonFilterRule rule = candidates[i];
                if (!ConditionsMatchSnapshot(rule.Conditions, fieldSnapshot))
                {
                    continue;
                }

                RuleChoice choice = BuildRuleChoice(rule);
                if (best == null || CompareRuleChoices(choice, best) > 0)
                {
                    best = choice;
                }
            }

            return best == null ? null : best.Rule;
        }

        private static Dictionary<string, ObjectFieldSnapshot> ReadRelevantObjectFields(
            ByteScanner scanner,
            long objectStartOffset,
            HashSet<string> requiredKeys)
        {
            Dictionary<string, ObjectFieldSnapshot> result =
                new Dictionary<string, ObjectFieldSnapshot>(StringComparer.Ordinal);

            foreach (string key in requiredKeys)
            {
                result[key] = new ObjectFieldSnapshot();
            }

            scanner.Seek(objectStartOffset);
            scanner.SkipWhitespace();
            Expect(scanner, '{');
            scanner.SkipWhitespace();

            if (scanner.Peek() == '}')
            {
                scanner.Read();
                return result;
            }

            while (true)
            {
                bool ignoredTruncation;
                string propertyName = ReadString(scanner, -1, out ignoredTruncation);
                scanner.SkipWhitespace();
                Expect(scanner, ':');
                scanner.SkipWhitespace();

                ObjectFieldSnapshot field;
                if (!result.TryGetValue(propertyName, out field))
                {
                    SkipValue(scanner);
                }
                else
                {
                    field.Exists = true;

                    int first = scanner.Peek();
                    if (first < 0)
                    {
                        throw new InvalidDataException("Unexpected end of JSON while matching object fields.");
                    }

                    string nodeType = GetNodeType(first);
                    if (nodeType == "string")
                    {
                        bool ignoredValueTruncation;
                        string valueHash;
                        ReadStringWithHash(scanner, 0, out ignoredValueTruncation, out valueHash);
                        field.ScalarValues.Add(BuildScalarKey("string", valueHash));
                    }
                    else if (nodeType == "number" || nodeType == "boolean" || nodeType == "null")
                    {
                        long ignoredEnd;
                        string token = ReadPrimitiveToken(scanner, -1, out ignoredEnd);
                        ValidatePrimitiveToken(token);
                        field.ScalarValues.Add(BuildScalarKey(nodeType, ComputeScalarHash(nodeType, token)));
                    }
                    else
                    {
                        SkipValue(scanner);
                    }
                }

                scanner.SkipWhitespace();
                int separator = scanner.Peek();
                if (separator == ',')
                {
                    scanner.Read();
                    scanner.SkipWhitespace();
                    continue;
                }

                if (separator == '}')
                {
                    scanner.Read();
                    return result;
                }

                throw new InvalidDataException("Expected ',' or '}' while matching JSON object fields.");
            }
        }

        private static bool ConditionsMatchSnapshot(
            JsonFieldCondition[] conditions,
            Dictionary<string, ObjectFieldSnapshot> snapshot)
        {
            if (conditions == null || conditions.Length == 0)
            {
                return true;
            }

            if (snapshot == null)
            {
                return false;
            }

            for (int i = 0; i < conditions.Length; i++)
            {
                JsonFieldCondition condition = conditions[i];
                if (condition == null)
                {
                    continue;
                }

                ObjectFieldSnapshot field;
                if (!snapshot.TryGetValue(condition.Key, out field) || !field.Exists)
                {
                    return false;
                }

                if (condition.MatchValue)
                {
                    string scalarKey = BuildScalarKey(condition.ValueType, condition.ValueHash);
                    if (!field.ScalarValues.Contains(scalarKey))
                    {
                        return false;
                    }
                }
            }

            return true;
        }

        private static string BuildScalarKey(string valueType, string valueHash)
        {
            return (valueType == null ? String.Empty : valueType) + "\u001F" +
                   (valueHash == null ? String.Empty : valueHash);
        }

        private static string ComputeScalarHash(string valueType, string valueText)
        {
            string combined =
                (valueType == null ? String.Empty : valueType) + "\u001F" +
                (valueText == null ? String.Empty : valueText);
            byte[] bytes = Encoding.UTF8.GetBytes(combined);
            using (SHA256 sha = SHA256.Create())
            {
                return BytesToHex(sha.ComputeHash(bytes));
            }
        }

        private static string BytesToHex(byte[] bytes)
        {
            StringBuilder builder = new StringBuilder(bytes.Length * 2);
            for (int i = 0; i < bytes.Length; i++)
            {
                builder.Append(bytes[i].ToString("x2", CultureInfo.InvariantCulture));
            }
            return builder.ToString();
        }

        private static bool RulePathMatches(JsonFilterRule rule, NodeContext context)
        {
            string mode = rule.PathMode == null ? "Anywhere" : rule.PathMode;
            string selector = rule.Selector == null ? String.Empty : rule.Selector;

            if (String.Equals(mode, "Exact", StringComparison.OrdinalIgnoreCase))
            {
                return String.Equals(selector, context.ExactPointer, StringComparison.Ordinal);
            }

            if (String.Equals(mode, "Structural", StringComparison.OrdinalIgnoreCase))
            {
                return String.Equals(selector, context.StructuralPointer, StringComparison.Ordinal);
            }

            if (String.Equals(mode, "Anywhere", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            throw new InvalidDataException("Unknown JSON rule path mode: " + mode);
        }

        private static RuleChoice BuildRuleChoice(JsonFilterRule rule)
        {
            int conditionCount = 0;
            int valueConditionCount = 0;

            if (rule.Conditions != null)
            {
                conditionCount = rule.Conditions.Length;
                for (int i = 0; i < rule.Conditions.Length; i++)
                {
                    JsonFieldCondition condition = rule.Conditions[i];
                    if (condition != null && condition.MatchValue)
                    {
                        valueConditionCount++;
                    }
                }
            }

            string scope = rule.Scope == null ? "Global" : rule.Scope;
            string pathMode = rule.PathMode == null ? "Anywhere" : rule.PathMode;

            int pathRank;
            if (String.Equals(pathMode, "Exact", StringComparison.OrdinalIgnoreCase))
            {
                pathRank = 3;
            }
            else if (String.Equals(pathMode, "Structural", StringComparison.OrdinalIgnoreCase))
            {
                pathRank = 2;
            }
            else
            {
                pathRank = 1;
            }

            return new RuleChoice
            {
                Rule = rule,
                ScopeRank = String.Equals(scope, "Local", StringComparison.OrdinalIgnoreCase) ? 2 : 1,
                PathRank = pathRank,
                ValueConditionCount = valueConditionCount,
                ConditionCount = conditionCount,
                NodeNameRank = String.IsNullOrEmpty(rule.NodeName) ? 0 : 1,
                ActionRank = IsIncludeAction(rule.Action) ? 1 : 0
            };
        }

        private static int CompareRuleChoices(RuleChoice left, RuleChoice right)
        {
            int value;

            value = left.ScopeRank.CompareTo(right.ScopeRank);
            if (value != 0) return value;

            value = left.PathRank.CompareTo(right.PathRank);
            if (value != 0) return value;

            value = left.ValueConditionCount.CompareTo(right.ValueConditionCount);
            if (value != 0) return value;

            value = left.ConditionCount.CompareTo(right.ConditionCount);
            if (value != 0) return value;

            value = left.NodeNameRank.CompareTo(right.NodeNameRank);
            if (value != 0) return value;

            value = left.ActionRank.CompareTo(right.ActionRank);
            if (value != 0) return value;

            string leftId = left.Rule.Id == null ? String.Empty : left.Rule.Id;
            string rightId = right.Rule.Id == null ? String.Empty : right.Rule.Id;
            return String.CompareOrdinal(rightId, leftId);
        }

        private static bool IsIncludeAction(string action)
        {
            return String.Equals(action, "Include", StringComparison.OrdinalIgnoreCase);
        }

        private static void WriteIndent(JsonOutputWriter writer, int indent)
        {
            for (int i = 0; i < indent; i++)
            {
                writer.Write("  ");
            }
        }

        private static void WriteJsonString(JsonOutputWriter writer, string value)
        {
            writer.Write('"');
            for (int i = 0; i < value.Length; i++)
            {
                char ch = value[i];
                switch (ch)
                {
                    case '"': writer.Write("\\\""); break;
                    case '\\': writer.Write("\\\\"); break;
                    case '\b': writer.Write("\\b"); break;
                    case '\f': writer.Write("\\f"); break;
                    case '\n': writer.Write("\\n"); break;
                    case '\r': writer.Write("\\r"); break;
                    case '\t': writer.Write("\\t"); break;
                    default:
                        if (ch < 0x20)
                        {
                            writer.Write("\\u");
                            writer.Write(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            writer.Write(ch);
                        }
                        break;
                }
            }
            writer.Write('"');
        }

        private static void SkipValue(ByteScanner scanner)
        {
            scanner.SkipWhitespace();
            int first = scanner.Peek();
            if (first < 0)
            {
                throw new InvalidDataException("Unexpected end of JSON while skipping a value.");
            }

            if (first == '"')
            {
                SkipString(scanner);
                return;
            }

            if (first == '{' || first == '[')
            {
                Stack<int> closers = new Stack<int>();
                int opener = scanner.Read();
                closers.Push(opener == '{' ? '}' : ']');

                while (closers.Count > 0)
                {
                    int value = scanner.Read();
                    if (value < 0)
                    {
                        throw new InvalidDataException("Unexpected end of JSON inside a container.");
                    }

                    if (value == '"')
                    {
                        SkipStringBody(scanner);
                        continue;
                    }

                    if (value == '{')
                    {
                        closers.Push('}');
                        continue;
                    }
                    if (value == '[')
                    {
                        closers.Push(']');
                        continue;
                    }
                    if (value == '}' || value == ']')
                    {
                        int expected = closers.Pop();
                        if (value != expected)
                        {
                            throw new InvalidDataException("Mismatched closing bracket in JSON.");
                        }
                    }
                }
                return;
            }

            bool sawAny = false;
            while (true)
            {
                int value = scanner.Peek();
                if (value < 0 || value == ',' || value == ']' || value == '}' || IsWhitespace(value))
                {
                    break;
                }
                sawAny = true;
                scanner.Read();
            }

            if (!sawAny)
            {
                throw new InvalidDataException("Invalid JSON value.");
            }
        }

        private static void SkipString(ByteScanner scanner)
        {
            Expect(scanner, '"');
            SkipStringBody(scanner);
        }

        private static void SkipStringBody(ByteScanner scanner)
        {
            while (true)
            {
                int value = scanner.Read();
                if (value < 0)
                {
                    throw new InvalidDataException("Unexpected end of JSON string.");
                }
                if (value == '"')
                {
                    return;
                }
                if (value == '\\')
                {
                    int escaped = scanner.Read();
                    if (escaped < 0)
                    {
                        throw new InvalidDataException("Unexpected end of JSON escape sequence.");
                    }
                    if (escaped == 'u')
                    {
                        for (int i = 0; i < 4; i++)
                        {
                            int hex = scanner.Read();
                            if (HexValue(hex) < 0)
                            {
                                throw new InvalidDataException("Invalid JSON Unicode escape sequence.");
                            }
                        }
                    }
                    continue;
                }
                if (value < 0x20)
                {
                    throw new InvalidDataException("Unescaped control character in JSON string.");
                }
            }
        }

        private static string ReadStringWithHash(
            ByteScanner scanner,
            int maxChars,
            out bool truncated,
            out string valueHash)
        {
            Expect(scanner, '"');
            StringBuilder builder = new StringBuilder();
            truncated = false;

            using (SHA256 sha = SHA256.Create())
            {
                while (true)
                {
                    int value = scanner.Read();
                    if (value < 0)
                    {
                        throw new InvalidDataException("Unexpected end of JSON string.");
                    }
                    if (value == '"')
                    {
                        sha.TransformFinalBlock(new byte[0], 0, 0);
                        valueHash = BytesToHex(sha.Hash);
                        return builder.ToString();
                    }
                    if (value < 0x20)
                    {
                        throw new InvalidDataException("Unescaped control character in JSON string.");
                    }

                    string piece;
                    if (value == '\\')
                    {
                        int escaped = scanner.Read();
                        if (escaped < 0)
                        {
                            throw new InvalidDataException("Unexpected end of JSON escape sequence.");
                        }

                        switch (escaped)
                        {
                            case '"': piece = "\""; break;
                            case '\\': piece = "\\"; break;
                            case '/': piece = "/"; break;
                            case 'b': piece = "\b"; break;
                            case 'f': piece = "\f"; break;
                            case 'n': piece = "\n"; break;
                            case 'r': piece = "\r"; break;
                            case 't': piece = "\t"; break;
                            case 'u':
                                int codeUnit = 0;
                                for (int i = 0; i < 4; i++)
                                {
                                    int hex = scanner.Read();
                                    int digit = HexValue(hex);
                                    if (digit < 0)
                                    {
                                        throw new InvalidDataException("Invalid JSON Unicode escape sequence.");
                                    }
                                    codeUnit = (codeUnit << 4) | digit;
                                }
                                piece = new string((char)codeUnit, 1);
                                break;
                            default:
                                throw new InvalidDataException("Invalid JSON escape sequence.");
                        }
                    }
                    else if (value < 0x80)
                    {
                        piece = new string((char)value, 1);
                    }
                    else
                    {
                        piece = ReadUtf8Sequence(scanner, value);
                    }

                    byte[] pieceBytes = new byte[piece.Length * 2];
                    for (int pieceIndex = 0; pieceIndex < piece.Length; pieceIndex++)
                    {
                        int codeUnit = piece[pieceIndex];
                        pieceBytes[pieceIndex * 2] = (byte)(codeUnit & 0xFF);
                        pieceBytes[pieceIndex * 2 + 1] = (byte)((codeUnit >> 8) & 0xFF);
                    }
                    sha.TransformBlock(pieceBytes, 0, pieceBytes.Length, pieceBytes, 0);

                    if (maxChars < 0 || builder.Length < maxChars)
                    {
                        int remaining = maxChars < 0 ? piece.Length : maxChars - builder.Length;
                        if (remaining >= piece.Length)
                        {
                            builder.Append(piece);
                        }
                        else if (remaining > 0)
                        {
                            builder.Append(piece.Substring(0, remaining));
                            truncated = true;
                        }
                        else
                        {
                            truncated = true;
                        }
                    }
                    else
                    {
                        truncated = true;
                    }
                }
            }
        }

        private static string ReadString(ByteScanner scanner, int maxChars, out bool truncated)
        {
            Expect(scanner, '"');
            StringBuilder builder = new StringBuilder();
            truncated = false;

            while (true)
            {
                int value = scanner.Read();
                if (value < 0)
                {
                    throw new InvalidDataException("Unexpected end of JSON string.");
                }
                if (value == '"')
                {
                    return builder.ToString();
                }
                if (value < 0x20)
                {
                    throw new InvalidDataException("Unescaped control character in JSON string.");
                }

                string piece;
                if (value == '\\')
                {
                    int escaped = scanner.Read();
                    if (escaped < 0)
                    {
                        throw new InvalidDataException("Unexpected end of JSON escape sequence.");
                    }

                    switch (escaped)
                    {
                        case '"': piece = "\""; break;
                        case '\\': piece = "\\"; break;
                        case '/': piece = "/"; break;
                        case 'b': piece = "\b"; break;
                        case 'f': piece = "\f"; break;
                        case 'n': piece = "\n"; break;
                        case 'r': piece = "\r"; break;
                        case 't': piece = "\t"; break;
                        case 'u':
                            int codeUnit = 0;
                            for (int i = 0; i < 4; i++)
                            {
                                int hex = scanner.Read();
                                int digit = HexValue(hex);
                                if (digit < 0)
                                {
                                    throw new InvalidDataException("Invalid JSON Unicode escape sequence.");
                                }
                                codeUnit = (codeUnit << 4) | digit;
                            }
                            piece = new string((char)codeUnit, 1);
                            break;
                        default:
                            throw new InvalidDataException("Invalid JSON escape sequence.");
                    }
                }
                else if (value < 0x80)
                {
                    piece = new string((char)value, 1);
                }
                else
                {
                    piece = ReadUtf8Sequence(scanner, value);
                }

                if (maxChars < 0 || builder.Length < maxChars)
                {
                    int remaining = maxChars < 0 ? piece.Length : maxChars - builder.Length;
                    if (remaining >= piece.Length)
                    {
                        builder.Append(piece);
                    }
                    else if (remaining > 0)
                    {
                        builder.Append(piece.Substring(0, remaining));
                        truncated = true;
                    }
                    else
                    {
                        truncated = true;
                    }
                }
                else
                {
                    truncated = true;
                }
            }
        }

        private static string ReadUtf8Sequence(ByteScanner scanner, int first)
        {
            int length;
            if ((first & 0xE0) == 0xC0)
            {
                length = 2;
            }
            else if ((first & 0xF0) == 0xE0)
            {
                length = 3;
            }
            else if ((first & 0xF8) == 0xF0)
            {
                length = 4;
            }
            else
            {
                throw new InvalidDataException("Invalid UTF-8 sequence in JSON string.");
            }

            byte[] bytes = new byte[length];
            bytes[0] = (byte)first;
            for (int i = 1; i < length; i++)
            {
                int next = scanner.Read();
                if (next < 0 || (next & 0xC0) != 0x80)
                {
                    throw new InvalidDataException("Invalid UTF-8 continuation byte in JSON string.");
                }
                bytes[i] = (byte)next;
            }

            return StrictUtf8.GetString(bytes);
        }

        private static string ReadPrimitiveToken(ByteScanner scanner, int maxChars, out long endOffset)
        {
            StringBuilder builder = new StringBuilder();
            bool truncated = false;
            while (true)
            {
                int value = scanner.Peek();
                if (value < 0 || value == ',' || value == ']' || value == '}' || IsWhitespace(value))
                {
                    break;
                }

                scanner.Read();
                if (maxChars < 0 || builder.Length < maxChars)
                {
                    builder.Append((char)value);
                }
                else
                {
                    truncated = true;
                }
            }

            if (builder.Length == 0 && !truncated)
            {
                throw new InvalidDataException("Invalid JSON primitive value.");
            }

            endOffset = scanner.Position;
            string valueText = builder.ToString();
            if (truncated)
            {
                valueText += "...";
            }
            return valueText;
        }

        private static void ValidatePrimitiveToken(string token)
        {
            if (token == "true" || token == "false" || token == "null")
            {
                return;
            }

            double ignored;
            if (!Double.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out ignored))
            {
                throw new InvalidDataException("Invalid JSON primitive token: " + token);
            }
        }

        private static string GetNodeType(int first)
        {
            if (first == '{') return "object";
            if (first == '[') return "array";
            if (first == '"') return "string";
            if (first == 't' || first == 'f') return "boolean";
            if (first == 'n') return "null";
            if (first == '-' || (first >= '0' && first <= '9')) return "number";
            throw new InvalidDataException("Unexpected token at JSON value start: 0x" + first.ToString("X2", CultureInfo.InvariantCulture));
        }

        private static void Expect(ByteScanner scanner, int expected)
        {
            int actual = scanner.Read();
            if (actual != expected)
            {
                throw new InvalidDataException("Expected '" + ((char)expected).ToString() + "' in JSON.");
            }
        }

        private static bool IsWhitespace(int value)
        {
            return value == 0x20 || value == 0x09 || value == 0x0A || value == 0x0D;
        }

        private static int HexValue(int value)
        {
            if (value >= '0' && value <= '9') return value - '0';
            if (value >= 'a' && value <= 'f') return value - 'a' + 10;
            if (value >= 'A' && value <= 'F') return value - 'A' + 10;
            return -1;
        }

        private static string EscapePreview(string value)
        {
            if (value == null)
            {
                return String.Empty;
            }

            StringBuilder builder = new StringBuilder();
            for (int i = 0; i < value.Length; i++)
            {
                char ch = value[i];
                if (ch == '\\') builder.Append("\\\\");
                else if (ch == '"') builder.Append("\\\"");
                else if (ch == '\r') builder.Append("\\r");
                else if (ch == '\n') builder.Append("\\n");
                else if (ch == '\t') builder.Append("\\t");
                else builder.Append(ch);
            }
            return builder.ToString();
        }

        private static string EncodePointerSegment(string segment)
        {
            return segment.Replace("~", "~0").Replace("/", "~1").Replace("*", "~2");
        }

        private static string AppendPointer(string parent, string encodedSegment)
        {
            if (String.IsNullOrEmpty(parent))
            {
                return "/" + encodedSegment;
            }
            return parent + "/" + encodedSegment;
        }
    }
}
