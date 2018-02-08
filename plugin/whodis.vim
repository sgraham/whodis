" Copyright 2018 The Chromium Authors. All rights reserved.
" Use of this source code is governed by a BSD-style license that can be
" found in the LICENSE file.
"
" Scott Graham <scott.whodis@h4ck3r.net>

if !has('python')
  s:ErrMsg("Error: vim with +python required")
  finish
endif

python <<endpython
import json
import os
import re
import shlex
import subprocess

def FindCompdbForFile(f):
  """
  '/Users/scottmg/work/crashpad/crashpad/test/mac/dyld.cc' -> 
  '/Users/scottmg/work/crashpad/crashpad/compile_commands.json'
  """
  if not os.path.isfile(f):
    raise ValueError('Expected file, but ' + f + ' is not')

  original = f
  while True:
    cur_dir = os.path.dirname(f)
    if f == cur_dir:
      raise ValueError(
          'compile_commands.json not found above ' + original + '\n' +
          'Run something like:\n' +
          '  ninja -C out/Release -t compdb cc cxx > compile_commands.json\n'
          'in the source root.\n')
    candidate = os.path.join(cur_dir, 'compile_commands.json')
    if os.path.isfile(candidate):
      return candidate
    f = cur_dir


def LoadCompdb(compdb_path):
  with open(compdb_path, 'rb') as f:
    commands = json.loads(f.read())
  result = {}
  for c in commands:
    path = os.path.normpath(os.path.join(c['directory'], c['file']))
    output = os.path.normpath(os.path.join(c['directory'], c['output']))
    result[path] = c['directory'], c['command'], output
  return result


def FindIndexForFile(cwd, file_directives, filename):
  for line in file_directives:
    parts = shlex.split(line)
    if len(parts) < 3:
      continue
    index, dirname, basename = parts
    candidate = os.path.normpath(os.path.join(cwd, dirname, basename))
    if candidate == filename:
      return index
  raise ValueError('Could not find TU for ' + filename)


def FindLineContainingCursor(asm_contents, tu_index, line_number):
  prefix = '\t.loc\t' + tu_index + ' ' + str(line_number)
  for i, line in enumerate(asm_contents):
    if line.startswith(prefix):
      return i


def FindFunctionStart(asm_contents, start_index):
  i = start_index - 1
  while not asm_contents[i].startswith('\t.globl\t'):
    i -= 1
  return i


def FindFunctionEnd(asm_contents, start_index):
  i = start_index + 1
  while not asm_contents[i].startswith('\t.cfi_endproc'):
    i += 1
  return i


def EnsureScratchBufferOpen():
  TEMP_BUFFER_NAME = '__whodis_asm_viewer__'
  def find_in_buffers():
    for b in vim.buffers:
      if b.name.endswith(TEMP_BUFFER_NAME):
        return b.number
    return -1

  def find_in_windows():
    for w in vim.windows:
      if w.buffer.name.endswith(TEMP_BUFFER_NAME):
        return w.number
    return -1

  # Check if a buffer is already created.
  buf_num = find_in_buffers()
  if buf_num == -1:
    vim.command('vnew ' + TEMP_BUFFER_NAME)
  else:
    # Buffer is already created, check if there's a window.
    win_num = find_in_windows()
    if win_num != -1:
      # Jump to it if it exists.
      vim.command(str(win_num) + 'wincmd w')
    else:
      buf_num = find_in_buffers()
      vim.command('vsplit +buffer' + str(buf_num))
  return vim.buffers[find_in_buffers()]


def DropMiscDirectives(contents):
  return [x for x in contents if not x.startswith('\t.cfi') and
                                 not x.startswith('\t##DEBUG_VALUE') and
                                 not re.match('Lcfi\d+:', x) and
                                 not re.match('Ltmp\d+:', x)]


def GetFileNameAndLineNumber(file_and_line_with_colons):
  """ '../../stuff.cc:42:3' -> ('../../stuff.cc', '42')
  """
  parts = file_and_line_with_colons.split(':')
  return parts[0], parts[1]


def GetSourceLine(cwd, file_name, line_number):
  # TODO: cache contents.
  with open(os.path.join(cwd, file_name), 'rb') as f:
    return f.readlines()[int(line_number) - 1]


def ReplaceLocWithCode(cwd, contents):
  result = []
  last_line = -1
  for line in contents:
    if line.startswith('\t.loc\t'):
      trailing_filename = line[line.find('#'):].lstrip('# ')
      file_name, line_number = GetFileNameAndLineNumber(trailing_filename)
      if line_number != last_line:
        result.append('# ' + file_name + ':' + line_number)
        if line_number != '0':
          result.append('# ' + GetSourceLine(cwd, file_name, line_number))
        last_line = line_number
    else:
      result.append(line)
  return result


endpython


function! WhoDis()

python <<endpython
import vim

name = vim.current.buffer.name
compdb = LoadCompdb(FindCompdbForFile(name))
cwd, command, output = compdb[name]

# Hackity hack to blah.o.S and append -S assuming that'll get us asm.
# Another way might be to use gobjdump -S, but it seems like not perfect output
# for what we want to do here.
output_to_find = os.path.relpath(output, cwd)
temp_asm = os.path.join(cwd, 'whodis.temp.S')
command_to_run = command.replace(output_to_find, temp_asm) + \
                 ' -S -g -masm=intel'
subprocess.check_call(shlex.split(command_to_run), cwd=cwd)

with open(temp_asm, 'rb') as f:
  asm_contents = f.readlines()
file_lines = [x[7:] for x in asm_contents if x.startswith('\t.file\t')]
tu_index = FindIndexForFile(cwd, file_lines, name)

cursor_line = vim.current.window.cursor[0]
line_index = FindLineContainingCursor(asm_contents, tu_index, cursor_line)
if not line_index:
  raise ValueError('Did not find any code for line ' + str(cursor_line))

function_start = FindFunctionStart(asm_contents, line_index)
function_end = FindFunctionEnd(asm_contents, line_index)

buf = EnsureScratchBufferOpen()
contents = DropMiscDirectives(asm_contents[function_start:function_end + 1])
contents = ReplaceLocWithCode(cwd, contents)
buf[:] = contents
endpython

endfunction

function! s:MarkBufferAsScratch()
    setlocal buftype=nofile
    setlocal bufhidden=hide
    setlocal noswapfile
    setlocal buflisted
    setlocal ft=asm
    setlocal ts=8
    map <silent> <nowait> <buffer> <Esc> :bd<cr>
    map <silent> <nowait> <buffer> <F11> :bd<cr>
endfunction

autocmd BufNewFile,BufEnter __whodis_asm_viewer__ call s:MarkBufferAsScratch()

if !exists('g:who_no_maps')
  map <silent> <F11> :call WhoDis()<cr>
endif
