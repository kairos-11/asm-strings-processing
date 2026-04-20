; lab3_full.asm
; Архитектура: x86_64, ОС: Linux
; Системные вызовы: syscall
; Без библиотек, без mmap. Полное соответствие требованиям лабы.

BITS 64
GLOBAL _start

SECTION .data
    prompt_msg  db 'Enter output filename: ', 0
    prompt_len  equ $ - prompt_msg

    err_open    db 'Error: cannot open file.', 10, 0
    err_open_len equ $ - err_open
    err_read    db 'Error: stdin read failed.', 10, 0
    err_read_len equ $ - err_read
    err_write   db 'Error: file write failed.', 10, 0
    err_write_len equ $ - err_write
    err_alloc   db 'Error: memory allocation failed.', 10, 0
    err_alloc_len equ $ - err_alloc

SECTION .bss
    filename_buf resb 256
    fd           resq 1          ; 64-битный дескриптор

    buf_ptr      resq 1          ; начало буфера
    buf_pos      resq 1          ; текущая позиция записи
    buf_limit    resq 1          ; конец выделенной области

    char_buf     resb 1

SECTION .text
_start:
    ; 1. Запрос имени файла
    mov rax, 1          ; sys_write
    mov rdi, 1          ; stdout
    mov rsi, prompt_msg
    mov rdx, prompt_len
    syscall

    ; Чтение имени (до 255 байт)
    mov rax, 0          ; sys_read
    mov rdi, 0          ; stdin
    mov rsi, filename_buf
    mov rdx, 256
    syscall
    cmp rax, 0
    jle exit_clean      ; EOF или ошибка -> выход

    ; Убираем '\n' в конце имени
    lea rdi, [rsi + rax - 1]
    cmp byte [rdi], 10
    jne .fn_no_nl
    mov byte [rdi], 0
    jmp .open_file
.fn_no_nl:
    mov byte [rdi + 1], 0

    ; 2. Открытие файла для вывода
.open_file:
    mov rax, 2          ; sys_open
    mov rdi, filename_buf
    mov rsi, 577        ; O_WRONLY(1) | O_CREAT(64) | O_TRUNC(512)
    mov rdx, 420        ; права 0644
    syscall
    cmp rax, 0
    jl err_open_fail
    mov [fd], rax

    ; 3. Инициализация динамического буфера
    call init_buffer

    ; 4. Основной цикл чтения
.read_loop:
    mov rax, 0          ; sys_read
    mov rdi, 0          ; stdin
    mov rsi, char_buf
    mov rdx, 1
    syscall
    cmp rax, 0
    je .eof_handle      ; 0 -> EOF
    jl err_read_fail    ; <0 -> ошибка

    movzx rdx, byte [char_buf] ; rdx = прочитанный символ

    ; Проверка переполнения буфера
    mov rax, [buf_pos]
    cmp rax, [buf_limit]
    jae .expand_buf

.store_char:
    mov rax, [buf_pos]
    mov [rax], dl
    inc qword [buf_pos]

    cmp dl, 10          ; '\n' ?
    je .write_line
    jmp .read_loop

    ; 5. Расширение буфера (+4 КБ)
.expand_buf:
    mov rax, [buf_limit]
    add rax, 4096
    mov rdi, rax
    mov rax, 12         ; sys_brk
    syscall
    cmp rax, -1
    je err_alloc_fail
    mov [buf_limit], rax
    jmp .store_char

    ; 6. Запись строки в файл (С ИНТЕГРИРОВАННОЙ ЛОГИКОЙ)
.write_line:
    ; rsi = начало строки, rdx = указатель на '\n'
    mov rsi, [buf_ptr]
    mov rdx, [buf_pos]
    call process_line   ; rax = указатель за последним символом результата

    ; Гарантируем перевод строки
    mov byte [rax], 10
    inc rax

    ; sys_write
    mov rdi, [fd]
    mov rsi, [buf_ptr]
    mov rdx, rax
    sub rdx, rsi        ; длина результата + '\n'
    mov rax, 1          ; sys_write
    syscall
    cmp rax, 0
    jl err_write_fail

    ; Сброс позиции для следующей строки
    mov rax, [buf_ptr]
    mov [buf_pos], rax
    jmp .read_loop

    ; 7. Обработка EOF
.eof_handle:
    mov rax, [buf_pos]
    mov rcx, [buf_ptr]
    cmp rax, rcx
    je .close_file      ; буфер пуст -> сразу закрываем

    ; Обрабатываем остаток (последняя строка без \n)
    mov rsi, [buf_ptr]
    mov rdx, [buf_pos]
    call process_line

    mov byte [rax], 10
    inc rax

    mov rdi, [fd]
    mov rsi, [buf_ptr]
    mov rdx, rax
    sub rdx, rsi
    mov rax, 1          ; sys_write
    syscall
    cmp rax, 0
    jl err_write_fail

.close_file:
    mov rax, 3          ; sys_close
    mov rdi, [fd]
    syscall

exit_clean:
    mov rax, 60         ; sys_exit
    xor rdi, rdi
    syscall

    ; --- Обработчики ошибок ---
err_open_fail:
    mov rax, 1; mov rdi, 1; mov rsi, err_open; mov rdx, err_open_len; syscall
    jmp exit_clean
err_read_fail:
    mov rax, 1; mov rdi, 1; mov rsi, err_read; mov rdx, err_read_len; syscall
    jmp exit_clean
err_write_fail:
    mov rax, 1; mov rdi, 1; mov rsi, err_write; mov rdx, err_write_len; syscall
    jmp exit_clean
err_alloc_fail:
    mov rax, 1; mov rdi, 1; mov rsi, err_alloc; mov rdx, err_alloc_len; syscall
    jmp exit_clean

    ; --- Инициализация буфера ---
init_buffer:
    mov rax, 12         ; sys_brk
    xor rdi, rdi
    syscall
    cmp rax, -1
    je err_alloc_fail

    mov rdi, rax
    add rdi, 4096
    mov rax, 12
    syscall
    cmp rax, -1
    je err_alloc_fail

    mov [buf_ptr], rdi
    mov [buf_pos], rdi
    mov [buf_limit], rax
    ret

    ; ----------------------------------------------------
    ; ФУНКЦИЯ: process_line
    ; Вход:  rsi = начало строки, rdx = указатель на '\n'
    ; Выход: rax = указатель за последним записанным символом
    ; Логика: Вариант №30 (in-place, O(N))
    ; ----------------------------------------------------
process_line:
    push rbx                ; callee-saved по SysV ABI
    mov rdi, rsi            ; rdi = write pointer (in-place)
    xor ebx, ebx            ; bl = целевой символ (0 = не установлен)
    xor r8b, r8b            ; r8b = флаг разделителя (0 = первое слово, 1 = нужен пробел)

.next_char:
    cmp rsi, rdx
    je .finish

    movzx eax, byte [rsi]
    cmp eax, ' '
    je .skip_sep
    cmp eax, 9              ; Tab
    je .skip_sep

    ; Начало нового слова
    cmp bl, 0
    jne .check_match
    mov bl, al              ; Запоминаем первый символ первого слова

.check_match:
    cmp al, bl
    jne .skip_word          ; Не совпадает -> пропускаем слово

    ; Совпадает! Вставляем пробел, если это не первое слово
    cmp r8b, 0
    je .no_sep
    mov byte [rdi], ' '
    inc rdi
.no_sep:
    mov r8b, 1              ; Следующие слова потребуют разделителя

    ; Копируем слово целиком
.copy_loop:
    mov [rdi], al
    inc rdi
    inc rsi
    cmp rsi, rdx
    je .finish
    movzx eax, byte [rsi]
    cmp eax, ' '
    je .word_done
    cmp eax, 9
    je .word_done
    jmp .copy_loop

.word_done:
    jmp .next_char

.skip_word:
    inc rsi
    cmp rsi, rdx
    je .finish
    movzx eax, byte [rsi]
    cmp eax, ' '
    je .skip_sep
    cmp eax, 9
    je .skip_sep
    jmp .skip_word

.skip_sep:
    inc rsi
    jmp .next_char

.finish:
    mov rax, rdi            ; Возвращаем конец записанных данных
    pop rbx
    ret
