#include "client.h"
#include "interop.h"
#include <memory>
#include <set>
#include <GL/glut.h>
#include "socket.h"

using boost::asio::ip::tcp;

int oldWidth = -1, oldHeight = -1, oldX = -1, oldY = -1;
bool resized = false;
std::shared_ptr<ClamContext> context;
std::shared_ptr<ClamInterop> interop;
std::shared_ptr<ClamKernel> kernel;
std::shared_ptr<tcp::socket> connection;

void displayFunc()
{
    if (kernel)
    {
        int width = glutGet(GLUT_WINDOW_WIDTH);
        int height = glutGet(GLUT_WINDOW_HEIGHT);
        oldX = glutGet(GLUT_WINDOW_X);
        oldY = glutGet(GLUT_WINDOW_Y);
        if (width != oldWidth || height != oldHeight)
        {
            oldWidth = width;
            oldHeight = height;
            interop->Resize(kernel, width, height);
        }
        interop->Blit(*kernel->GetQueue());
        glutSwapBuffers();
    }
}

void idleFunc()
{
    if (connection->is_open() == false)
    {
        puts("Server stream closed, shutting down");
        exit(0);
    }
    while (connection->available())
    {
        unsigned int messageType = read<unsigned int>(*connection, 1)[0];
        switch (messageType)
        {
            case MessageNull:
                break;
            case MessageKernelInvoke:
                {
                    auto kernName = readStr(*connection);
                    for (int index = 0;; index++)
                    {
                        int arglen = read<int>(*connection, 1)[0];
                        if (arglen == 0)
                            break;
                        else if (arglen == -1) // buffer name
                        {
                            auto arg = interop->GetBuffer(readStr(*connection));
                            kernel->SetArg(kernName, index, sizeof(*arg), arg.get());
                        }
                        else if (arglen == -2) // *FOUR* parameters, x, y, width, height
                        {
                            kernel->SetArg(kernName, index++, sizeof(int), &oldX);
                            kernel->SetArg(kernName, index++, sizeof(int), &oldY);
                            kernel->SetArg(kernName, index++, sizeof(int), &interop->width);
                            kernel->SetArg(kernName, index, sizeof(int), &interop->height);
                        }
                        else
                        {
                            auto arg = read<uint8_t>(*connection, arglen);
                            kernel->SetArg(kernName, index, arglen, arg.data());
                        }
                    }
                    kernel->Invoke(kernName);
                    send<uint8_t>(*connection, {0});
                }
                break;
            case MessageKernelSource:
                {
                    auto sourcecode = readStr(*connection);
                    kernel = std::make_shared<ClamKernel>(context->GetContext(),
                            context->GetDevice(), sourcecode.c_str());
                    send<uint8_t>(*connection, {0});
                }
                break;
            case MessageKill:
                puts("Caught shutdown signal, closing");
                exit(0);
                break;
            default:
                throw std::runtime_error("Unknown packet id " + std::to_string(messageType));
        }
    }
    glutPostRedisplay();
}

void client(int port)
{
    boost::asio::io_service service;
    tcp::acceptor acceptor(service, tcp::endpoint(tcp::v4(), port));
    connection = std::make_shared<tcp::socket>(service);
    puts("Waiting for connection");
    acceptor.accept(*connection);
    puts("Connected, starting render client");

    glutInitDisplayMode(GLUT_DOUBLE);
    glutCreateWindow("Clam2");
    // TODO: Figure out what screen to put ourselves on
    //glutFullScreen();
    context = std::make_shared<ClamContext>();
    interop = std::make_shared<ClamInterop>(context->GetContext());

    glutDisplayFunc(displayFunc);
    glutIdleFunc(idleFunc);
    glutMainLoop();
}
